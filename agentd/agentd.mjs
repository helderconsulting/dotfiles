import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { Bridge } from "./bridge.mjs";
import { Daemon } from "./daemon.mjs";
import { SessionStore } from "./sessions.mjs";
import claude from "./providers/claude.mjs";

const home = os.homedir();
const root = path.join(process.env.XDG_STATE_HOME || path.join(home, ".local/state"), "workspace");
const socketPath = path.join(root, "agentd.sock");
const here = path.dirname(new URL(import.meta.url).pathname);
const sources = () => [
	path.join(here, "agentd.mjs"),
	path.join(here, "daemon.mjs"),
	path.join(here, "bridge.mjs"),
	path.join(here, "sessions.mjs"),
	...fs.readdirSync(path.join(here, "providers")).map((f) => path.join(here, "providers", f)),
];
const fingerprint = () => sources().map((f) => `${f}:${fs.statSync(f).mtimeMs}`).join("|");
const loaded = fingerprint();

function log(event, data = {}) {
	process.stdout.write(JSON.stringify({ at: Date.now() / 1000, event, ...data }) + "\n");
}

const running = await new Promise((resolve) => {
	const probe = net.connect(socketPath, () => {
		probe.end();
		resolve(true);
	});
	probe.on("error", () => resolve(false));
});
if (running) {
	log("already.running", { socket: socketPath });
	process.exit(0);
}

const bridge = new Bridge({
	command: "nvim",
	args: ["--clean", "-l", path.join(home, ".config/lua/workspace/cli/main.lua"), "bridge"],
	env: { ...process.env, PATH: `/opt/homebrew/bin:/usr/local/bin:${process.env.PATH}` },
	log,
	onState: (state) => daemon?.bridgeState(state),
});

let server;
const daemon = new Daemon({
	providers: [claude],
	store: new SessionStore(path.join(root, "agentd", "sessions.json")),
	bridge,
	log,
	stale: () => fingerprint() !== loaded,
	onShutdown: () => {
		server?.close();
		try {
			fs.unlinkSync(socketPath);
		} catch {}
		process.exit(0);
	},
});

function serve(conn) {
	let buffer = "";
	conn.setEncoding("utf8");
	conn.on("data", async (chunk) => {
		buffer += chunk;
		const end = buffer.indexOf("\n");
		if (end < 0) return;
		const line = buffer.slice(0, end);
		buffer = "";
		let reply;
		let keep = false;
		try {
			const result = await daemon.handle(JSON.parse(line), conn);
			keep = result?.keep === true;
			reply = { ok: true, ...result };
		} catch (err) {
			reply = { ok: false, error: err.message, code: err.code };
		}
		if (keep) conn.write(JSON.stringify(reply) + "\n");
		else conn.end(JSON.stringify(reply) + "\n");
	});
	conn.on("error", () => {});
}

fs.mkdirSync(root, { recursive: true });
try {
	fs.unlinkSync(socketPath);
} catch {}
server = net.createServer(serve);
server.listen(socketPath, async () => {
	log("listening", { socket: socketPath, pid: process.pid });
	const resumed = await daemon.boot();
	log("booted", { resumed });
});

process.on("SIGTERM", () => daemon.shutdown("SIGTERM"));
process.on("SIGINT", () => daemon.shutdown("SIGINT"));
