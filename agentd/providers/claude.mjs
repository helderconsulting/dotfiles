import { randomUUID } from "node:crypto";
import { query } from "@anthropic-ai/claude-agent-sdk";
import { Provider, Session } from "./provider.mjs";

const windowNames = { five_hour: "5h", seven_day: "week", seven_day_opus: "week opus", seven_day_sonnet: "week sonnet" };
const catalogTtl = 3600 * 1000;
const planTimeout = 20000;
const forwarded = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Stop", "SessionEnd"];
const windows = new Map();

class Inbox {
	#items = [];
	#wake = null;
	#closed = false;

	push(text) {
		this.#items.push({ type: "user", message: { role: "user", content: text }, parent_tool_use_id: null });
		this.#wake?.();
	}

	close() {
		this.#closed = true;
		this.#wake?.();
	}

	async *messages(gate) {
		await gate;
		for (;;) {
			while (this.#items.length) yield this.#items.shift();
			if (this.#closed) return;
			await new Promise((resolve) => (this.#wake = resolve));
			this.#wake = null;
		}
	}
}

function usageOf(info) {
	const list = Object.entries(info?.unifiedWindows ?? {}).map(([key, w]) => ({
		name: windowNames[key] ?? key.replaceAll("_", " "),
		used: w.utilization ?? 0,
		resets_at: w.resetsAt,
		status: w.status,
	}));
	return { windows: list, overage: info?.overageStatus, extra: info?.isUsingOverage === true };
}

function planProblem(account) {
	if (process.env.ANTHROPIC_API_KEY) return "ANTHROPIC_API_KEY is set, usage would be billed to the API";
	if (account.apiProvider && account.apiProvider !== "firstParty") return `signed in through ${account.apiProvider}, not a plan`;
	if (!account.subscriptionType) return "no subscription on this login, usage would be billed to the API";
	if (account.apiKeySource && account.apiKeySource !== "none") return `using an API key from ${account.apiKeySource}`;
	return null;
}

function childEnv() {
	const env = { ...process.env, AGENTD_SESSION: "1", WEZTERM_PANE: "" };
	delete env.ANTHROPIC_API_KEY;
	return env;
}

function contextUsed(usage) {
	if (!usage) return null;
	return (usage.input_tokens ?? 0) + (usage.cache_read_input_tokens ?? 0) + (usage.cache_creation_input_tokens ?? 0);
}

function modelList(models) {
	return models.map((m) => ({ value: m.value, label: m.displayName, description: m.description }));
}

function withTimeout(promise, ms, message) {
	return Promise.race([promise, new Promise((_, reject) => setTimeout(() => reject(new Error(message)), ms))]);
}

class ClaudeSession extends Session {
	#inbox = new Inbox();
	#query;
	#pass;
	#fail;
	#started;
	#done;
	#asks = 0;

	constructor({ cwd, prompt, model, mode, resume, host }) {
		super({ id: resume ?? randomUUID(), provider: "claude", cwd, model, mode: mode ?? "auto", host });
		const gate = new Promise((resolve, reject) => {
			this.#pass = resolve;
			this.#fail = reject;
		});
		gate.catch(() => {});
		this.#query = query({
			prompt: this.#inbox.messages(gate),
			options: {
				cwd,
				model,
				permissionMode: this.mode,
				...(resume ? { resume } : { sessionId: this.id }),
				env: childEnv(),
				hooks: Object.fromEntries(forwarded.map((event) => [event, [{ hooks: [(input) => this.#hook(input)] }]])),
				canUseTool: (tool, input, options) => this.#ask(tool, input, options),
			},
		});
		this.#started = this.#checkPlan().then(
			(account) => this.#open(prompt, account),
			(err) => this.#refuse(err),
		);
		this.#done = this.#consume();
	}

	get started() {
		return this.#started;
	}

	get done() {
		return this.#done;
	}

	async #checkPlan() {
		const account = await withTimeout(this.#query.accountInfo(), planTimeout, "the plan check timed out");
		const problem = planProblem(account);
		if (problem) throw new Error(problem);
		return account;
	}

	#open(prompt, account) {
		this.#pass();
		if (prompt) this.#inbox.push(prompt);
		this.report("verify", { model: this.model, mode: this.mode, plan: account.subscriptionType });
		return this.id;
	}

	#refuse(err) {
		this.#fail(err);
		this.#inbox.close();
		this.#query.close();
		this.report("reject", { reason: err.message });
		throw err;
	}

	async #hook(input) {
		if (input.hook_event_name === "UserPromptSubmit") this.#setBusy(true);
		else if (input.hook_event_name === "Stop") this.#setBusy(false);
		if (input.cwd && input.cwd !== this.cwd) {
			this.cwd = input.cwd;
			this.changed();
		}
		try {
			return (await this.host.hook(input)) ?? {};
		} catch {
			return {};
		}
	}

	#setBusy(busy) {
		if (this.busy === busy) return;
		this.busy = busy;
		this.changed();
	}

	async #ask(tool, input, { signal, suggestions, toolUseID }) {
		const request = toolUseID ?? `${this.id}-${++this.#asks}`;
		const cancel = () => this.host.cancel(request);
		signal?.addEventListener("abort", cancel, { once: true });
		try {
			return await this.host.ask({ session: this.id, tool, input, suggestions, cwd: this.cwd, request });
		} catch (err) {
			return { behavior: "deny", message: `couldn't ask the user: ${err.message}` };
		} finally {
			signal?.removeEventListener("abort", cancel);
		}
	}

	async #consume() {
		try {
			for await (const m of this.#query) this.#observe(m);
		} catch (err) {
			return err.message;
		}
	}

	#observe(m) {
		if (m.type === "system" && m.subtype === "init") {
			this.model = m.model;
			if (m.apiKeySource && m.apiKeySource !== "none") {
				this.report("reject", { reason: `using an API key from ${m.apiKeySource}` });
				this.stop();
			} else {
				this.report("model", { model: m.model });
			}
		} else if (m.type === "system" && m.subtype === "status" && m.permissionMode && m.permissionMode !== this.mode) {
			this.mode = m.permissionMode;
			this.changed();
			this.report("mode", { mode: m.permissionMode });
		} else if (m.type === "rate_limit_event") {
			this.reportUsage(usageOf(m.rate_limit_info));
		} else if (m.type === "assistant" && !m.parent_tool_use_id) {
			this.context = contextUsed(m.message?.usage) ?? this.context;
			const window = windows.get(this.model);
			if (this.context && window) this.report("context", { used: this.context, window });
		} else if (m.type === "result") {
			for (const [model, u] of Object.entries(m.modelUsage ?? {})) if (u.contextWindow) windows.set(model, u.contextWindow);
			const window = windows.get(this.model) ?? Math.max(0, ...Object.values(m.modelUsage ?? {}).map((u) => u.contextWindow ?? 0));
			if (this.context && window) this.report("context", { used: this.context, window });
		}
	}

	send(text) {
		this.#inbox.push(text);
	}

	async interrupt() {
		await this.#query.interrupt();
	}

	async setModel(model) {
		await this.#query.setModel(model);
		this.model = model;
		this.changed();
		this.report("model", { model });
	}

	async setMode(mode) {
		await this.#query.setPermissionMode(mode);
		this.mode = mode;
		this.changed();
		this.report("mode", { mode });
	}

	async models() {
		return modelList(await this.#query.supportedModels());
	}

	stop() {
		this.#inbox.close();
		this.#query.close();
	}
}

export class ClaudeProvider extends Provider {
	#catalog = null;

	get name() {
		return "claude";
	}

	async models(cwd) {
		if (this.#catalog && Date.now() - this.#catalog.at < catalogTtl) return this.#catalog.models;
		let release;
		const hold = new Promise((resolve) => (release = resolve));
		async function* idle() {
			await hold;
		}
		const q = query({ prompt: idle(), options: { cwd, settingSources: [], env: childEnv() } });
		try {
			const models = modelList(await q.supportedModels());
			this.#catalog = { at: Date.now(), models };
			return models;
		} finally {
			release();
			q.close();
		}
	}

	open(options) {
		return new ClaudeSession(options);
	}
}

export default new ClaudeProvider();
