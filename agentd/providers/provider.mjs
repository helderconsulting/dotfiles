function abstract(self, method) {
	return new Error(`${self.constructor.name} must implement ${method}`);
}

export class Provider {
	get name() {
		throw abstract(this, "name");
	}

	async models(_cwd) {
		throw abstract(this, "models(cwd)");
	}

	open(_options) {
		throw abstract(this, "open({ cwd, prompt, model, mode, resume, host })");
	}
}

export class Session {
	constructor({ id, provider, cwd, model, mode, host }) {
		this.id = id;
		this.provider = provider;
		this.cwd = cwd;
		this.model = model;
		this.mode = mode;
		this.busy = false;
		this.context = null;
		this.host = host;
	}

	get started() {
		throw abstract(this, "started");
	}

	get done() {
		throw abstract(this, "done");
	}

	send(_text) {
		throw abstract(this, "send(text)");
	}

	async interrupt() {
		throw abstract(this, "interrupt()");
	}

	async setModel(_model) {
		throw abstract(this, "setModel(model)");
	}

	async setMode(_mode) {
		throw abstract(this, "setMode(mode)");
	}

	async models() {
		throw abstract(this, "models()");
	}

	stop() {
		throw abstract(this, "stop()");
	}

	report(event, fields = {}) {
		this.host.report({ type: "runtime", id: this.id, provider: this.provider, event, ...fields });
	}

	reportUsage(usage) {
		this.host.report({ type: "usage", provider: this.provider, ...usage });
	}

	changed() {
		this.host.changed(this);
	}
}
