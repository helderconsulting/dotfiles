import { Provider } from "./providers/provider.mjs";

export const continuePrompt =
	"agentd restarted while you were working, so your last turn was cut off. Continue the task from where you stopped.";

export const limitPrompt = "The usage limit you hit has reset. Continue the task from where you stopped.";

export class Daemon {
	#providers;
	#store;
	#bridge;
	#log;
	#grace;
	#stale;
	#onShutdown;
	#clock;
	#limitSlack;
	#sessions = new Map();
	#wakes = new Map();
	#announced = new WeakSet();
	#holders = new Set();
	#idle = null;
	#closing = false;
	#draining = false;

	constructor({ providers, store, bridge, log = () => {}, grace = 8000, stale = () => false, onShutdown = () => {}, clock = () => Date.now(), limitSlack = 30000 }) {
		this.#providers = Object.fromEntries(
			providers.map((p) => {
				if (!(p instanceof Provider)) throw new Error(`${p?.constructor?.name} is not a Provider`);
				return [p.name, p];
			}),
		);
		this.#store = store;
		this.#bridge = bridge;
		this.#log = log;
		this.#grace = grace;
		this.#stale = stale;
		this.#onShutdown = onShutdown;
		this.#clock = clock;
		this.#limitSlack = limitSlack;
	}

	get sessions() {
		return [...this.#sessions.keys()];
	}

	get holders() {
		return this.#holders.size;
	}

	get draining() {
		return this.#draining;
	}

	broadcast(event) {
		const line = JSON.stringify(event) + "\n";
		for (const conn of this.#holders) conn.write?.(line);
	}

	bridgeState(state) {
		this.#log("bridge.state", { state });
		if (state === "up") this.#resync();
		this.broadcast({ event: "bridge", state });
	}

	#resync() {
		const live = [...this.#sessions.values()].filter((s) => this.#announced.has(s));
		this.#bridge.send("sync", { sessions: live.map((s) => s.id) });
		for (const s of live) {
			this.#bridge.send("started", { id: s.id, cwd: s.cwd });
			this.#bridge.send("runtime", { report: { type: "runtime", id: s.id, provider: s.provider, event: "verify", model: s.model, mode: s.mode } });
		}
	}

	async boot() {
		const saved = this.#store.list();
		this.#bridge.send("sync", { sessions: [], saved: saved.map((entry) => entry.id) });
		for (const entry of saved) {
			const prompt = entry.busy ? continuePrompt : undefined;
			this.#open({ ...entry, resume: entry.id, prompt })
				.then((session) => entry.limited && session.limit(entry.limited))
				.catch((err) => this.#log("resume.failed", { id: entry.id, error: err.message }));
		}
		this.#armIdle();
		return saved.length;
	}

	#host() {
		return {
			report: (payload) => this.#bridge.send("runtime", { report: payload }),
			hook: (payload) => this.#bridge.request("hook", { payload }),
			ask: (req) => this.#bridge.request("ask", req),
			cancel: (request) => this.#bridge.send("cancel", { request }),
			changed: (session) => {
				if (this.#sessions.has(session.id)) this.#store.save(session);
				this.#armWake(session);
				this.#drainCheck();
			},
		};
	}

	async #open({ provider = "claude", id, cwd, prompt, model, mode, resume }) {
		const impl = this.#providers[provider];
		if (!impl) throw new Error(`no provider ${provider}`);
		const session = impl.open({ id, cwd, prompt, model, mode, resume, host: this.#host() });
		this.#sessions.set(session.id, session);
		session.done.then((error) => this.#ended(session, error));
		try {
			await session.started;
		} catch (err) {
			this.#sessions.delete(session.id);
			this.#store.forget(session.id);
			throw Object.assign(err, { code: "plan" });
		}
		this.#store.save(session);
		this.#announced.add(session);
		this.#bridge.send("started", { id: session.id, cwd: session.cwd });
		this.#log("session.start", { id: session.id, provider, cwd, resumed: Boolean(resume) });
		return session;
	}

	#ended(session, error) {
		if (this.#sessions.get(session.id) !== session) return;
		this.#sessions.delete(session.id);
		this.#disarmWake(session.id);
		if (!this.#closing) this.#store.forget(session.id);
		this.#log("session.end", { id: session.id, error, kept: this.#closing });
		this.#bridge.send("runtime", { report: { type: "runtime", id: session.id, provider: session.provider, event: "lose", reason: error } });
	}

	#armWake(session) {
		const due = session.limited?.resets_at ?? null;
		if ((this.#wakes.get(session.id)?.due ?? null) === due) return;
		this.#disarmWake(session.id);
		if (due === null) return;
		const timer = setTimeout(() => this.#wake(session), Math.max(0, due * 1000 - this.#clock()) + this.#limitSlack);
		this.#wakes.set(session.id, { due, timer });
	}

	#disarmWake(id) {
		clearTimeout(this.#wakes.get(id)?.timer);
		this.#wakes.delete(id);
	}

	#wake(session) {
		this.#wakes.delete(session.id);
		if (this.#sessions.get(session.id) !== session || !session.limited) return;
		this.#log("limit.resume", { id: session.id });
		session.send(limitPrompt);
	}

	#find(id) {
		const session = this.#sessions.get(id);
		if (!session) throw Object.assign(new Error(`no session ${id} here`), { code: "unknown" });
		return session;
	}

	hold(conn) {
		this.#holders.add(conn);
		this.#disarmIdle();
		conn.on("close", () => {
			this.#holders.delete(conn);
			this.#armIdle();
		});
	}

	#busy() {
		return [...this.#sessions.values()].some((s) => s.busy);
	}

	#drainCheck() {
		if (this.#draining && !this.#busy()) this.shutdown("code changed");
	}

	#armIdle() {
		if (this.#holders.size > 0 || this.#closing || this.#draining) return;
		if (this.#stale()) {
			if (!this.#busy()) return this.shutdown("code changed");
			this.#draining = true;
			this.#log("drain", { busy: [...this.#sessions.values()].filter((s) => s.busy).map((s) => s.id) });
			return;
		}
		this.#disarmIdle();
		this.#idle = setTimeout(() => {
			if (this.#holders.size === 0) this.shutdown("no workspace holds agentd");
		}, this.#grace);
	}

	#disarmIdle() {
		if (this.#idle) clearTimeout(this.#idle);
		this.#idle = null;
	}

	async shutdown(reason) {
		if (this.#closing) return;
		this.#closing = true;
		this.#disarmIdle();
		for (const id of this.#wakes.keys()) this.#disarmWake(id);
		this.#log("shutdown", { reason, sessions: this.#sessions.size });
		this.broadcast({ event: "shutdown", reason });
		const done = [...this.#sessions.values()].map((s) => {
			s.stop();
			return s.done;
		});
		await Promise.race([Promise.all(done), new Promise((resolve) => setTimeout(resolve, 3000))]);
		this.#bridge.close();
		this.#onShutdown(reason);
	}

	ops = {
		ping: async () => ({ providers: Object.keys(this.#providers), sessions: this.sessions, holders: this.#holders.size }),

		hold: async (_req, conn) => {
			this.hold(conn);
			return { keep: true, bridge: this.#bridge.state ?? "up", draining: this.#draining };
		},

		catalog: async ({ cwd }) => {
			const list = [];
			for (const [name, impl] of Object.entries(this.#providers)) {
				try {
					list.push({ provider: name, models: await impl.models(cwd) });
				} catch (err) {
					list.push({ provider: name, models: [], error: err.message });
				}
			}
			return { providers: list };
		},

		start: async ({ provider, id, cwd, prompt, model, mode, resume }) => {
			if (resume && this.#sessions.has(resume)) {
				if (prompt) this.#sessions.get(resume).send(prompt);
				return { id: resume };
			}
			const session = await this.#open({ provider, id, cwd, prompt, model, mode, resume });
			return { id: session.id };
		},

		send: async ({ id, text }) => {
			this.#find(id).send(text);
			return {};
		},

		interrupt: async ({ id }) => {
			await this.#find(id).interrupt();
			return {};
		},

		model: async ({ id, model }) => {
			await this.#find(id).setModel(model);
			return {};
		},

		mode: async ({ id, mode }) => {
			await this.#find(id).setMode(mode);
			return {};
		},

		models: async ({ id }) => ({ models: await this.#find(id).models() }),

		stop: async ({ id }) => {
			const session = this.#find(id);
			this.#store.forget(id);
			session.stop();
			return {};
		},
	};

	async handle(req, conn) {
		const op = this.ops[req.op];
		if (!op) throw new Error(`unknown op ${req.op}`);
		return op(req, conn);
	}
}
