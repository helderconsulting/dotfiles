import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Daemon, continuePrompt } from "../daemon.mjs";
import { SessionStore } from "../sessions.mjs";
import { FakeBridge, FakeProvider, FakeStore, conn } from "./fakes.mjs";

function daemon(overrides = {}) {
	const provider = overrides.provider ?? new FakeProvider();
	const store = overrides.store ?? new FakeStore();
	const bridge = new FakeBridge();
	let shutdown = null;
	const d = new Daemon({ providers: [provider], store, bridge, grace: 20, stale: overrides.stale, onShutdown: (r) => (shutdown = r) });
	return { d, provider, store, bridge, shutdown: () => shutdown };
}

const tick = (ms = 0) => new Promise((r) => setTimeout(r, ms));

test("refuses anything that isn't a Provider", () => {
	assert.throws(() => new Daemon({ providers: [{ name: "x" }], store: new FakeStore(), bridge: new FakeBridge() }));
});

test("a started session is saved and gets its prompt", async () => {
	const { d, provider, store } = daemon();
	const { id } = await d.handle({ op: "start", provider: "fake", cwd: "/p", prompt: "hi", model: "small" });
	assert.equal(provider.opened[0].sent[0], "hi");
	assert.deepEqual(store.entries[id], { provider: "fake", cwd: "/p", model: "small", mode: "auto", busy: false });
});

test("a refused plan isn't saved and says why", async () => {
	const provider = new FakeProvider();
	provider.refuse = "no subscription";
	const { d, store } = daemon({ provider });
	await assert.rejects(d.handle({ op: "start", provider: "fake", cwd: "/p" }), (err) => err.code === "plan");
	assert.deepEqual(store.list(), []);
});

test("send, interrupt, model and mode reach the session and are saved", async () => {
	const { d, provider, store } = daemon();
	const { id } = await d.handle({ op: "start", provider: "fake", cwd: "/p" });
	await d.handle({ op: "send", id, text: "more" });
	await d.handle({ op: "interrupt", id });
	await d.handle({ op: "model", id, model: "large" });
	await d.handle({ op: "mode", id, mode: "plan" });
	const s = provider.opened[0];
	assert.deepEqual(s.sent, ["more"]);
	assert.equal(s.interrupted, 1);
	assert.equal(store.entries[id].model, "large");
	assert.equal(store.entries[id].mode, "plan");
	await assert.rejects(d.handle({ op: "send", id: "nope", text: "x" }), (err) => err.code === "unknown");
});

test("stopping forgets the session and reports it lost", async () => {
	const { d, store, bridge } = daemon();
	const { id } = await d.handle({ op: "start", provider: "fake", cwd: "/p" });
	await d.handle({ op: "stop", id });
	await tick();
	assert.equal(store.entries[id], undefined);
	assert.ok(bridge.sent.some((m) => m.op === "runtime" && m.report.event === "lose" && m.report.id === id));
	assert.deepEqual(d.sessions, []);
});

test("shutdown keeps sessions so the next daemon resumes them, busy ones continue", async () => {
	const store = new FakeStore();
	const first = daemon({ store });
	const a = await first.d.handle({ op: "start", provider: "fake", cwd: "/a" });
	const b = await first.d.handle({ op: "start", provider: "fake", cwd: "/b" });
	first.provider.opened[1].work(true);
	await first.d.shutdown("test");
	assert.equal(first.shutdown(), "test");
	assert.ok(first.bridge.closed);
	assert.equal(store.list().length, 2);

	const second = daemon({ store });
	assert.equal(await second.d.boot(), 2);
	await tick();
	assert.deepEqual(second.bridge.sent[0], { op: "sync", sessions: [] });
	const resumed = Object.fromEntries(second.provider.opened.map((s) => [s.id, s]));
	assert.deepEqual(resumed[a.id].sent, []);
	assert.deepEqual(resumed[b.id].sent, [continuePrompt]);
	assert.deepEqual(second.d.sessions.sort(), [a.id, b.id].sort());
	assert.equal(second.bridge.sent.filter((m) => m.op === "started").length, 2);
});

test("the last holder leaving shuts down after the grace, a returning one keeps it", async () => {
	const { d, shutdown } = daemon();
	const c1 = conn();
	await d.handle({ op: "hold" }, c1);
	assert.equal(d.holders, 1);
	c1.emit("close");
	const c2 = conn();
	await d.handle({ op: "hold" }, c2);
	await tick(40);
	assert.equal(shutdown(), null);
	c2.emit("close");
	await tick(40);
	assert.equal(shutdown(), "no workspace holds agentd");
});

test("changed code shuts down as soon as nobody holds it", async () => {
	const { d, shutdown } = daemon({ stale: () => true });
	const c = conn();
	await d.handle({ op: "hold" }, c);
	c.emit("close");
	await tick();
	assert.equal(shutdown(), "code changed");
});

test("the catalog lists every provider's models", async () => {
	const { d } = daemon();
	const { providers } = await d.handle({ op: "catalog", cwd: "/p" });
	assert.deepEqual(providers, [{ provider: "fake", models: [{ value: "small" }] }]);
});

test("the session store survives a reload", () => {
	const file = path.join(fs.mkdtempSync(path.join(os.tmpdir(), "agentd-")), "sessions.json");
	const store = new SessionStore(file);
	store.save({ id: "x", provider: "fake", cwd: "/p", model: "m", mode: "auto", busy: true });
	assert.deepEqual(new SessionStore(file).list(), [{ id: "x", provider: "fake", cwd: "/p", model: "m", mode: "auto", busy: true }]);
	store.forget("x");
	assert.deepEqual(new SessionStore(file).list(), []);
});

test("changed code waits for busy sessions before restarting", async () => {
	const { d, provider, shutdown } = daemon({ stale: () => true });
	await d.handle({ op: "start", provider: "fake", cwd: "/p" });
	const s = provider.opened[0];
	s.work(true);
	const c = conn();
	await d.handle({ op: "hold" }, c);
	c.emit("close");
	await tick();
	assert.equal(shutdown(), null);
	assert.ok(d.draining);
	s.work(false);
	await tick();
	assert.equal(shutdown(), "code changed");
});

test("holders hear about the bridge and the shutdown", async () => {
	const { d } = daemon();
	const c = conn();
	const reply = await d.handle({ op: "hold" }, c);
	assert.equal(reply.bridge, "up");
	d.bridgeState("lost");
	await d.shutdown("test");
	assert.deepEqual(c.lines, [{ event: "bridge", state: "lost" }, { event: "shutdown", reason: "test" }]);
});
