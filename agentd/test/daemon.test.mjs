import { test } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { Daemon, continuePrompt, limitPrompt } from "../daemon.mjs";
import { LimitWatch } from "../providers/claude.mjs";
import { SessionStore } from "../sessions.mjs";
import { FakeBridge, FakeProvider, FakeStore, conn } from "./fakes.mjs";

function daemon(overrides = {}) {
	const provider = overrides.provider ?? new FakeProvider();
	const store = overrides.store ?? new FakeStore();
	const bridge = new FakeBridge();
	let shutdown = null;
	const d = new Daemon({
		providers: [provider],
		store,
		bridge,
		grace: 20,
		stale: overrides.stale,
		onShutdown: (r) => (shutdown = r),
		clock: overrides.clock,
		limitSlack: overrides.limitSlack ?? 0,
	});
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

test("a session started with a chosen id keeps it", async () => {
	const { d, store } = daemon();
	const { id } = await d.handle({ op: "start", provider: "fake", id: "picked", cwd: "/p", prompt: "hi" });
	assert.equal(id, "picked");
	assert.ok(store.entries.picked);
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
	assert.deepEqual(second.bridge.sent[0], { op: "sync", sessions: [], saved: [a.id, b.id] });
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

test("a returning bridge hears the live sessions again", async () => {
	const { d, bridge } = daemon();
	const started = await d.handle({ op: "start", provider: "fake", cwd: "/w", prompt: "hi" });
	bridge.sent = [];
	d.bridgeState("failed");
	assert.deepEqual(bridge.sent, []);
	d.bridgeState("up");
	assert.deepEqual(bridge.sent[0], { op: "sync", sessions: [started.id] });
	assert.deepEqual(bridge.sent[1], { op: "started", id: started.id, cwd: "/w" });
	assert.equal(bridge.sent[2].op, "runtime");
	assert.equal(bridge.sent[2].report.event, "verify");
	assert.equal(bridge.sent[2].report.id, started.id);
});

const limitHit = {
	type: "assistant",
	parent_tool_use_id: null,
	error: "rate_limit",
	message: { model: "<synthetic>", content: [{ type: "text", text: "You've hit your 5-hour limit · resets 1:30pm (Europe/Brussels)" }] },
};

test("a usage limit stop is read from the rejected window and the synthetic error", () => {
	const watch = new LimitWatch();
	assert.equal(watch.observe({ type: "rate_limit_event", rate_limit_info: { status: "allowed_warning", rateLimitType: "five_hour" } }), null);
	assert.equal(watch.observe({ type: "rate_limit_event", rate_limit_info: { status: "rejected", resetsAt: 1793881800, rateLimitType: "five_hour" } }), null);
	assert.equal(watch.observe({ ...limitHit, parent_tool_use_id: "toolu_1" }), null);
	assert.equal(watch.observe({ type: "assistant", parent_tool_use_id: null, message: {} }), null);
	assert.deepEqual(watch.observe(limitHit), { resets_at: 1793881800, window: "5h" });
	assert.deepEqual(new LimitWatch().observe(limitHit), {});
});

test("a limited session stops being busy, says when it resets and a new prompt lifts it", async () => {
	const { d, provider, store, bridge } = daemon({ clock: () => 0 });
	const { id } = await d.handle({ op: "start", provider: "fake", cwd: "/p" });
	const s = provider.opened[0];
	s.work(true);
	s.limit({ resets_at: 3600, window: "5h" });
	assert.equal(s.busy, false);
	assert.deepEqual(store.entries[id].limited, { resets_at: 3600, window: "5h" });
	const report = bridge.sent.find((m) => m.op === "runtime" && m.report.event === "limit").report;
	assert.deepEqual(report, { type: "runtime", id, provider: "fake", event: "limit", resets_at: 3600, window: "5h" });
	s.work(true);
	assert.equal(s.limited, null);
	assert.equal(store.entries[id].limited, undefined);
	await d.shutdown("test");
	assert.deepEqual(s.sent, []);
});

test("a limited session continues on its own once the limit resets", async () => {
	let now = 0;
	const { d, provider } = daemon({ clock: () => now });
	await d.handle({ op: "start", provider: "fake", cwd: "/p" });
	const s = provider.opened[0];
	s.limit({ resets_at: 0.02 });
	await tick(5);
	assert.deepEqual(s.sent, []);
	await tick(40);
	assert.deepEqual(s.sent, [limitPrompt]);
	s.limit({ resets_at: 0 });
	s.work(true);
	await tick(10);
	assert.deepEqual(s.sent, [limitPrompt]);
	await d.shutdown("test");
});

test("a restarted agentd keeps a session limited and still wakes it", async () => {
	const store = new FakeStore();
	store.entries.lim = { provider: "fake", cwd: "/p", model: "m", mode: "auto", busy: false, limited: { resets_at: 0, window: "5h" } };
	const { d, provider, bridge } = daemon({ store, clock: () => 1000 });
	await d.boot();
	await tick(10);
	const s = provider.opened[0];
	assert.deepEqual(s.sent, [limitPrompt]);
	assert.ok(bridge.sent.some((m) => m.op === "runtime" && m.report.event === "limit" && m.report.id === "lim"));
	await d.shutdown("test");
});
