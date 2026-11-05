import { EventEmitter } from "node:events";
import { Provider, Session } from "../providers/provider.mjs";

export class FakeSession extends Session {
	#finish;
	#done;
	#started;

	constructor({ id, cwd, prompt, model, mode, resume, host, refuse }) {
		super({ id: resume ?? id ?? `s${++FakeSession.count}`, provider: "fake", cwd, model, mode: mode ?? "auto", host });
		this.sent = prompt ? [prompt] : [];
		this.interrupted = 0;
		this.stopped = false;
		this.#done = new Promise((resolve) => (this.#finish = resolve));
		this.#started = refuse ? Promise.reject(new Error(refuse)) : Promise.resolve(this.id);
		this.#started.catch(() => this.#finish("refused"));
	}

	static count = 0;

	get started() {
		return this.#started;
	}

	get done() {
		return this.#done;
	}

	send(text) {
		this.sent.push(text);
	}

	async interrupt() {
		this.interrupted++;
	}

	async setModel(model) {
		this.model = model;
		this.changed();
	}

	async setMode(mode) {
		this.mode = mode;
		this.changed();
	}

	async models() {
		return [{ value: "small" }, { value: "large" }];
	}

	stop() {
		this.stopped = true;
		this.#finish();
	}

	work(busy) {
		this.setBusy(busy);
	}
}

export class FakeProvider extends Provider {
	opened = [];
	refuse = null;

	get name() {
		return "fake";
	}

	async models() {
		return [{ value: "small" }];
	}

	open(options) {
		const session = new FakeSession({ ...options, refuse: this.refuse });
		this.opened.push(session);
		return session;
	}
}

export class FakeBridge {
	sent = [];
	closed = false;

	send(op, fields) {
		this.sent.push({ op, ...fields });
	}

	async request(op, fields) {
		this.sent.push({ op, ...fields });
		return null;
	}

	close() {
		this.closed = true;
	}
}

export class FakeStore {
	entries = {};

	list() {
		return Object.entries(this.entries).map(([id, e]) => ({ id, ...e }));
	}

	save(s) {
		this.entries[s.id] = { provider: s.provider, cwd: s.cwd, model: s.model, mode: s.mode, busy: s.busy, ...(s.limited ? { limited: s.limited } : {}) };
	}

	forget(id) {
		delete this.entries[id];
	}
}

export function conn() {
	const c = new EventEmitter();
	c.lines = [];
	c.write = (line) => c.lines.push(JSON.parse(line));
	return c;
}
