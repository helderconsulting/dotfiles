import fs from "node:fs";
import path from "node:path";

export class SessionStore {
	#file;
	#entries;

	constructor(file) {
		this.#file = file;
		try {
			this.#entries = JSON.parse(fs.readFileSync(file, "utf8"));
		} catch {
			this.#entries = {};
		}
	}

	list() {
		return Object.entries(this.#entries).map(([id, entry]) => ({ id, ...entry }));
	}

	save(session) {
		this.#entries[session.id] = { provider: session.provider, cwd: session.cwd, model: session.model, mode: session.mode, busy: session.busy, ...(session.limited ? { limited: session.limited } : {}) };
		this.#write();
	}

	forget(id) {
		if (!(id in this.#entries)) return;
		delete this.#entries[id];
		this.#write();
	}

	#write() {
		fs.mkdirSync(path.dirname(this.#file), { recursive: true });
		const tmp = `${this.#file}.tmp`;
		fs.writeFileSync(tmp, JSON.stringify(this.#entries, null, 2));
		fs.renameSync(tmp, this.#file);
	}
}
