import { spawn } from "node:child_process";

export class Bridge {
	#command;
	#args;
	#env;
	#log;
	#child = null;
	#buffer = "";
	#next = 1;
	#pending = new Map();
	#exits = [];
	#closing = false;
	#onState;
	#retryAfter;
	#retry = null;
	state = "up";

	constructor({ command, args, env, log, onState = () => {}, retryAfter = 60000 }) {
		this.#command = command;
		this.#args = args;
		this.#env = env;
		this.#log = log;
		this.#onState = onState;
		this.#retryAfter = retryAfter;
		this.#spawn();
	}

	#setState(state) {
		if (this.state === state) return;
		this.state = state;
		this.#onState(state);
	}

	#spawn() {
		const child = spawn(this.#command, this.#args, { stdio: ["pipe", "pipe", "inherit"], env: this.#env });
		this.#child = child;
		child.on("spawn", () => this.#setState("up"));
		child.stdout.setEncoding("utf8");
		child.stdout.on("data", (chunk) => this.#read(chunk));
		child.on("error", (err) => this.#log("bridge.error", { error: err.message }));
		child.on("exit", (code) => this.#exited(child, code));
		child.stdin.on("error", () => {});
	}

	#exited(child, code) {
		if (child !== this.#child) return;
		for (const { reject } of this.#pending.values()) reject(new Error("the bridge exited"));
		this.#pending.clear();
		if (this.#closing) return;
		const now = Date.now();
		this.#exits = [...this.#exits.filter((t) => now - t < 10000), now];
		this.#log("bridge.exit", { code, restarts: this.#exits.length });
		if (this.#exits.length >= 3) {
			this.#log("bridge.gave_up", { retry_in: this.#retryAfter });
			this.#setState("failed");
			this.#retry = setTimeout(() => {
				this.#retry = null;
				this.#exits = [];
				this.#log("bridge.retry");
				this.#spawn();
			}, this.#retryAfter);
			this.#retry.unref?.();
			return;
		}
		this.#setState("lost");
		this.#spawn();
	}

	#read(chunk) {
		this.#buffer += chunk;
		let end;
		while ((end = this.#buffer.indexOf("\n")) >= 0) {
			const line = this.#buffer.slice(0, end);
			this.#buffer = this.#buffer.slice(end + 1);
			let msg;
			try {
				msg = JSON.parse(line);
			} catch {
				continue;
			}
			const waiter = this.#pending.get(msg.id);
			if (!waiter) continue;
			this.#pending.delete(msg.id);
			if (msg.error) waiter.reject(new Error(msg.error));
			else waiter.resolve(msg.result ?? null);
		}
	}

	#write(msg) {
		if (!this.#child || this.#child.exitCode !== null) return false;
		this.#child.stdin.write(JSON.stringify(msg) + "\n");
		return true;
	}

	send(op, fields = {}) {
		this.#write({ op, ...fields });
	}

	request(op, fields = {}) {
		const id = this.#next++;
		return new Promise((resolve, reject) => {
			this.#pending.set(id, { resolve, reject });
			if (!this.#write({ id, op, ...fields })) {
				this.#pending.delete(id);
				reject(new Error("the bridge isn't running"));
			}
		});
	}

	close() {
		this.#closing = true;
		clearTimeout(this.#retry);
		this.#retry = null;
		this.#child?.stdin.end();
	}
}
