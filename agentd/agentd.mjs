import fs from "node:fs";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { StateBridge } from "./state_bridge.mjs";
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
	path.join(here, "state_bridge.mjs"),
	path.join(here, "sessions.mjs"),
	...fs.readdirSync(path.join(here, "providers")).map((f) => path.join(here, "providers", f)),
];
const fingerprint = () => sources().map((f) => `${f}:${fs.statSync(f, { throwIfNoEntry: false })?.mtimeMs ?? "gone"}`).join("|");
const loaded = fingerprint();

function log(event, data = {}) {
	process.stdout.write(JSON.stringify({ at: Date.now() / 1000, event, ...data }) + "\n");
}

const alive = () =>
	new Promise((resolve) => {
		const probe = net.connect(socketPath, () => {
			probe.end();
			resolve(true);
		});
		probe.on("error", () => resolve(false));
	});

const inode = () => {
	try {
		return fs.statSync(socketPath).ino;
	} catch {
		return null;
	}
};

const listen = () =>
	new Promise((resolve, reject) => {
		const s = net.createServer(serve);
		s.once("error", reject);
		s.listen(socketPath, () => {
			s.off("error", reject);
			resolve(s);
		});
	});

async function claim() {
	try {
		return await listen();
	} catch (err) {
		if (err.code !== "EADDRINUSE") throw err;
	}
	const stale = inode();
	if (await alive()) return null;
	if (inode() === stale) {
		try {
			fs.unlinkSync(socketPath);
		} catch {}
	}
	try {
		return await listen();
	} catch (err) {
		if (err.code === "EADDRINUSE") return null;
		throw err;
	}
}

fs.mkdirSync(root, { recursive: true });
const server = await claim();
if (!server) {
	log("already.running", { socket: socketPath });
	process.exit(0);
}
const owned = inode();

const bridge = new StateBridge({
	command: "nvim",
	args: ["--clean", "-l", path.join(home, ".config/lua/workspace/cli/main.lua"), "bridge"],
	env: { ...process.env, PATH: `/opt/homebrew/bin:/usr/local/bin:${process.env.PATH}` },
	log,
	onState: (state) => daemon?.bridgeState(state),
});

const daemon = new Daemon({
	providers: [claude],
	store: new SessionStore(path.join(root, "agentd", "sessions.json")),
	bridge,
	log,
	stale: () => fingerprint() !== loaded,
	onShutdown: () => {
		server.close();
		if (inode() === owned) {
			try {
				fs.unlinkSync(socketPath);
			} catch {}
		}
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

log("listening", { socket: socketPath, pid: process.pid });
log("booted", { resumed: await daemon.boot() });

process.on("SIGTERM", () => daemon.shutdown("SIGTERM"));
process.on("SIGINT", () => daemon.shutdown("SIGINT"));
