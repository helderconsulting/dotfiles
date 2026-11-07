import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { StateBridge } from "../state_bridge.mjs";

const until = async (check, ms = 3000) => {
	const end = Date.now() + ms;
	while (!check()) {
		if (Date.now() > end) throw new Error("timed out");
		await new Promise((r) => setTimeout(r, 10));
	}
};

test("a bridge that gave up is started again later", async () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), "bridge-"));
	const runs = path.join(dir, "runs");
	const script = `echo x >> ${runs}; [ $(wc -l < ${runs}) -gt 3 ] && exec cat; exit 1`;
	const states = [];
	const logged = [];
	const bridge = new StateBridge({
		command: "sh",
		args: ["-c", script],
		env: process.env,
		log: (event) => logged.push(event),
		onState: (state) => states.push(state),
		retryAfter: 200,
	});
	try {
		await until(() => states.includes("failed"));
		assert.ok(logged.includes("bridge.gave_up"));
		assert.equal(fs.readFileSync(runs, "utf8").trim().split("\n").length, 3);
		await until(() => states.at(-1) === "up" && logged.includes("bridge.retry"));
		await until(() => fs.readFileSync(runs, "utf8").trim().split("\n").length === 4);
		await new Promise((r) => setTimeout(r, 100));
		assert.equal(bridge.state, "up");
	} finally {
		bridge.close();
	}
});

test("closing a bridge that gave up stops the retry", async () => {
	const logged = [];
	const bridge = new StateBridge({ command: "sh", args: ["-c", "exit 1"], env: process.env, log: (e) => logged.push(e), retryAfter: 100 });
	await until(() => bridge.state === "failed");
	bridge.close();
	await new Promise((r) => setTimeout(r, 250));
	assert.ok(!logged.includes("bridge.retry"));
});
