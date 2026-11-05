local base = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0]))))
package.path = base .. "/?.lua;" .. base .. "/?/init.lua;" .. package.path

local nvim = require("workspace.nvim")
local paths = require("workspace.paths")
local store_mod = require("workspace.store")
local models = require("workspace.models")
local Agent, Review, Ask, Resource, Workspace, View = models.Agent, models.Review, models.Ask, models.Resource, models.Workspace, models.View
local Transcript = models.Transcript

local function make_store(root)
	return store_mod.new({ paths = paths.new(vim.env.HOME, root), fs = nvim.fs, json = nvim.json, clock = nvim.clock, random = math.random })
end

if arg[1] == "increment" then
	local store = make_store(arg[2])
	for _ = 1, 10 do
		store:update(Agent, "counter", function(a)
			a.pid = (a.pid or 0) + 1
		end)
	end
	return
end

local failures, count = {}, 0
local function check(name, cond, detail)
	count = count + 1
	if not cond then
		table.insert(failures, name .. (detail and (": " .. vim.inspect(detail)) or ""))
	end
end

local function test(name, fn)
	local ok, err = pcall(fn)
	check(name, ok, err)
end

test("agent lifecycle", function()
	local a = Agent:new({ id = "abcdef1234" })
	check("starts", a.state == "starting")
	for _, step in ipairs({ { "start", "idle" }, { "prompt", "working" }, { "tool", "working" }, { "ask", "waiting" }, { "answer", "working" }, { "stop", "done" }, { "start", "idle" }, { "end", "stopped" }, { "start", "idle" } }) do
		a:apply(step[1], 1)
		check("agent " .. step[1], a.state == step[2], a.state)
	end
	check("rejected answer while idle", not a:apply("answer", 2) and a.state == "idle")
	local t = a:take_transitions()
	check("transitions recorded", #t == 10 and t[10].rejected == true, #t)
	check("short", a:short() == "abcdef12")
end)

test("agent hooks map", function()
	check("start", Agent.hook_event({ hook_event_name = "SessionStart" }) == "start")
	check("question", Agent.hook_event({ hook_event_name = "PreToolUse", tool_name = "AskUserQuestion" }) == "ask")
	check("other pre is work", Agent.hook_event({ hook_event_name = "PreToolUse", tool_name = "Bash" }) == "tool")
	local busy = Agent:new({ id = "busy", state = "working", updated = 100 })
	busy:note_tool("PreToolUse", "Bash", { command = "npm test", description = "Run the tests" }, 100)
	check("shows the running tool", busy:progress(130) == "Bash: Run the tests · 30s", busy:progress(130))
	busy:note_tool("PostToolUse", "Bash", { command = "npm test" }, 200)
	check("last tool between tools", busy:progress(212) == "last Bash: npm test · 12s", busy:progress(212))
	check("thinking before any tool", Agent:new({ id = "t", state = "working", updated = 5 }):progress(9) == "thinking · 4s")
	local text, tone = busy:progress(200 + Agent.quiet_after + 60)
	check("quiet for a while", text == "quiet for 6m" and tone == "bad", text)
	busy:note_tool("PreToolUse", "mcp__plugin_gitlab_gitlab__get_job", { url = "x" }, 300)
	check("mcp tools are short", busy.doing.label == "get_job: x", busy.doing)
	busy:apply("stop", 310)
	check("a stop clears it", busy.doing == nil and busy:progress(320) == nil)
	check("permission note", Agent.hook_event({ hook_event_name = "Notification", notification_type = "permission_prompt" }) == "ask")
	check("idle note", Agent.hook_event({ hook_event_name = "Notification", notification_type = "idle_prompt" }) == nil)
end)

test("agent reconcile and status", function()
	local a = Agent:new({ id = "s1", state = "working", updated = 0 })
	check("settles when idle", a:reconcile({ status = "idle" }, true, 10) and a.state == "idle")
	check("ends when gone", a:reconcile(nil, false, 11) and a.state == "stopped")
	check("revives", a:reconcile({ status = "idle" }, true, 12) and a.state == "idle")
	local b = Agent:new({ id = "s2", state = "working", updated = 100 })
	check("registry older than the last hook is ignored", not b:reconcile({ status = "waiting", statusUpdatedAt = 99000 }, true, 101))
	check("dialog open in the terminal", b:reconcile({ status = "waiting", statusUpdatedAt = 100500 }, true, 101) and b.state == "waiting")
	check("question held by the workspace stays", not b:reconcile({ status = "busy", statusUpdatedAt = 102000 }, true, 103, true) and b.state == "waiting")
	check("answered in the terminal", b:reconcile({ status = "busy", statusUpdatedAt = 102000 }, true, 103) and b.state == "working")
	local named = Agent:new({ id = "n", state = "idle", name = "6ec84ec0" })
	check("picks up claude's name for the session", named:reconcile({ status = "idle", name = "singular span subjects" }, true, 10) and named:display_name() == "singular span subjects")
	check("same name changes nothing", not named:reconcile({ status = "idle", name = "singular span subjects" }, true, 11))
	check("interrupt settles after a pause",not b:reconcile({ status = "idle", statusUpdatedAt = 104000 }, true, 105) and b:reconcile({ status = "idle", statusUpdatedAt = 104000 }, true, 108) and b.state == "idle")
	b:apply("stop", 109)
	check("stop after settling still marks done", b.state == "done")
	local c = Agent:new({ id = "s3", state = "working" })
	c:receive_message(1)
	c:apply("prompt", 1)
	check("message status is the state", c:status() == "working")
	local r = Agent:new({ id = "r", state = "idle", updated = 10 })
	r:receive_message(12)
	check("message is unread", r:unread())
	check("reading marks it", r:mark_read(12) and not r:unread())
	check("reading again writes nothing", not r:mark_read(11))
	r:apply("prompt", 13)
	r:apply("stop", 20)
	check("finished turn is unread", r:unread() and r.state == "done")
	r:mark_read(20)
	check("read turn", not r:unread() and r.state == "done")
	a.state = "waiting"
	check("can't receive while waiting", not a:can_receive())
	a.root = "/x/y"
	check("within", a:within("/x") and not a:within("/xy"))
end)

test("publishing waits for approval", function()
	local mr = "mcp__plugin_gitlab_gitlab__save_merge_request"
	local create = "glab mr " .. "create --fill"
	check("creating an mr publishes", Review.publishing(mr, { project_id = "x", title = "t" }) == "open a merge request")
	check("updating an mr doesn't", Review.publishing(mr, { project_id = "x", merge_request_iid = 3 }) == nil)
	check("merging publishes", Review.publishing("mcp__gitlab__accept_merge_request", { sha = "a" }) == "merge a merge request")
	check("cli mrs publish", Review.publishing("Bash", { command = "cd x && " .. create }) ~= nil and Review.publishing("Bash", { command = "git push -u origin x -o merge_request." .. "create" }) ~= nil)
	check("mentions don't", Review.publishing("Bash", { command = "echo '" .. create .. "'" }) == nil and Review.publishing("Bash", { command = "grep " .. create }) == nil)
	check("other commands don't", Review.publishing("Bash", { command = "git push" }) == nil and Review.publishing("Read", {}) == nil)
	local r = Review:new({ id = Review.key("/repo"), root = "/repo" })
	check("no review blocks", Review.for_root("/repo"):publish_block("open a merge request", "t1", "review") ~= nil)
	check("an unapproved review blocks", r:publish_block("open a merge request", "t1", "review") ~= nil)
	r:mark_ready("done", "s", 1)
	check("ready isn't approved", r:publish_block("open a merge request", "t1", "review") ~= nil)
	r:approve("s", 2, "t1")
	check("approved code passes", r:publish_block("open a merge request", "t1", "review") == nil)
	check("changed code blocks", (r:publish_block("open a merge request", "t2", "review") or ""):match("changed") ~= nil)
	r:mark_ready("more", "s", 3)
	check("a new ready drops the approval", r:publish_block("open a merge request", "t1", "review") ~= nil)
	local mcp = { hook_event_name = "PreToolUse", tool_name = mr, tool_input = { project_id = "x", title = "t" } }
	check("the hook guards mr tools only", Review.guards(mcp) and not Review.guards({ hook_event_name = "PreToolUse", tool_name = "Read" }))
	local ctx = { branch = "feature", protected = { main = true, master = true }, tree = function()
		return "t1"
	end }
	check("the guard denies", r:guard(mcp, ctx, "review").hookSpecificOutput.permissionDecision == "deny")
end)

test("review flow", function()
	local r = Review:new({ id = Review.key("/repo"), root = "/repo" })
	local c = r:add({ path = "a.lua", line1 = 1, line2 = 2, text = "fix" }, math.random, 1)
	check("draft", c.state == "draft" and r.state == "open")
	check("approve refused with drafts", not r:approve("s", 2))
	r:send(r:drafts(), 3)
	check("sent", c.state == "sent" and r.state == "changes")
	check("gate lists", r:gate_message("review") ~= nil)
	check("resolve", r:resolve(c.id, "done", 4) and c.state == "resolved")
	check("gate clear", r:gate_message("review") == nil)
	check("approve before ready refused", not r:approve("s", 5))
	r:mark_ready("all done", "s", 6)
	check("ready", r.state == "ready")
	check("approve", r:approve("s", 7) and r.state == "approved")
	local again = Review:new(vim.json.decode(vim.json.encode(r:to_table())))
	check("roundtrip", again:comment(c.id).state == "resolved" and again.state == "approved")
	local d = again:add({ path = "b", line1 = 1, text = "x" }, math.random, 8)
	check("delete", again:delete(d.id, 9) and not again:comment(d.id))
	local t = again:take_transitions()
	check("delete transition logged", #t >= 1 and t[#t].to == "deleted", t)
	check("resolve unknown", not again:resolve("zzzz", "", 10))
end)

test("ask decisions", function()
	local a = Ask.from_hook({ session_id = "s", hook_event_name = "PermissionRequest", tool_name = "Bash", tool_input = { command = "ls" }, permission_suggestions = { { type = "addRules", rules = { { toolName = "Bash", ruleContent = "ls" } } } } }, "1", 5, 0)
	check("permission kind", a.kind == "permission" and #a:permission_choices() == 3)
	check("summary", a:summary() == "Bash: ls")
	a:decide("always", 1)
	check("always output", a.state == "answered" and a.output.hookSpecificOutput.decision.updatedPermissions ~= nil)
	check("answer text", a:answer_text() == "always allowed")
	local q = Ask.from_hook({ session_id = "s", hook_event_name = "PreToolUse", tool_name = "AskUserQuestion", tool_input = { questions = { { question = "which?", options = { { label = "a" } } } } } }, "2", 5, 0)
	q:answer({ ["which?"] = "a" }, 1)
	check("question output", q.output.hookSpecificOutput.permissionDecision == "allow" and q:answer_text() == "a")
	check("stale", Ask:new({ state = "pending", created = 0 }):is_stale(1000, true))
end)

test("resource lifecycle", function()
	local r = Resource:new({ id = "c1" })
	r:observe("exited", "off", 0)
	check("off", r.state == "off")
	r:start(1)
	r:observe("exited", "off", 2)
	check("still starting", r.state == "starting" and r:label() == "starting")
	r:observe("up", "ok", 3)
	check("running", r.state == "running" and r:label() == "up")
	r:stop(4)
	r:tick(100)
	check("timeout", r.state == "failed")
end)

test("workspace layout is responsive", function()
	local w = Workspace:new({ id = "1" })
	for _, total in ipairs({ 60, 90, 120, 173, 220, 300, 347 }) do
		local s = w:widths(total)
		check("all visible at " .. total, s.sidebar >= 1 and s.conversation >= 1 and s.editor >= 1, s)
		check("adds up at " .. total, s.sidebar + s.conversation + s.editor + 2 == total, s)
		if total >= 120 then
			check("editor gets half at " .. total, s.editor >= math.floor(total / 2) or s.conversation == 32, s)
		end
	end
	local wide = w:widths(347)
	check("wide uses ideals", wide.sidebar == 44 and wide.conversation == 78, wide)
	local mid = w:widths(173)
	check("mid shrinks conversation first", mid.sidebar == 44 and mid.conversation < 78 and mid.editor >= 86, mid)
	local n = Workspace:new({ id = "2", mode = "nvim" }):widths(200)
	check("nvim mode", n.conversation == nil and n.sidebar + n.editor + 1 == 200, n)
	check("diff layout", Workspace.diff_layout(86) == "inline" and Workspace.diff_layout(223) == "side-by-side")
	check("panel width", Workspace.panel_width(74) == 18 and Workspace.panel_width(200) == 35 and Workspace.panel_width(120) == 30)
	check("missing", #w:missing(function()
		return false
	end) == 4)
end)

test("view modes", function()
	local v = View:new({ id = "1" })
	v:compose({ cwd = "/x" })
	check("draft", v.state == "draft")
	v:show_ask("a1")
	v:settle_ask(true)
	check("back to draft", v.state == "draft")
	v:finish_compose()
	check("answer", v.state == "answer" and v.draft == nil)
end)

test("rules live in the models", function()
	local Registry = models.Registry
	local alive = function(pid)
		return pid ~= 2
	end
	local reg = Registry.new({ { sessionId = "a", pid = 1, status = "idle", cwd = "/p" }, { sessionId = "b", pid = 2 }, { sessionId = "c", pid = 3, parkedJobId = "x" }, { sessionId = "d", pid = 4, name = "dee", status = "busy", cwd = "/q" } }, alive)
	local a = Agent:new({ id = "a", state = "working", updated = 0, root = "/p" })
	check("needs reconcile", reg:needs_reconcile(a) and reg:reconcile(a, 10) and a.state == "idle")
	local gone = Agent:new({ id = "b", state = "idle" })
	check("dead ends", reg:reconcile(gone, 10) and gone.state == "stopped")
	local untracked = reg:untracked({ a = true })
	check("untracked skips parked and dead", #untracked == 1 and untracked[1].sessionId == "d", untracked)
	local d = Agent:new({ id = "d" })
	Registry.adopt(d, untracked[1], 11)
	check("adopt busy", d.state == "working" and d.root == "/q")
	check("recipient by name", reg:recipient("dee [x]").sessionId == "d")
	check("recipient by socket", reg:recipient("uds:/tmp/cc-socks/1.sock").sessionId == "a")
	a:bind_pane("23", false)
	check("pane channel", a:channel() == "pane" and a.pane == 23)
	a:bind_pane("23", true)
	check("attach channel", a:channel() == "attach")
	check("relocates", Agent.relocates_on("prompt") and not Agent.relocates_on("tool"))
	check("open starts nothing", Workspace.launch("workspace") == nil)
	check("launch resume", Workspace.launch("session:abc").resume == "abc")
	local picked, list = Review.recipient({ a, d }, "/p", nil)
	check("recipient here", picked == a)
	picked, list = Review.recipient({ a, d }, "/none", nil)
	check("recipient choose", picked == nil and #list == 2)
	local b = Agent:new({ id = "b", state = "working", root = "/p", name = "bee" })
	picked, list = Review.recipient({ a, b, d }, "/p", "b")
	check("two agents in the repo ask, the viewed one first", picked == nil and #list == 2 and list[1] == b, list)
	local asks = { Ask:new({ id = "2", session = "a", state = "pending", created = 0 }), Ask:new({ id = "1", session = "a", state = "pending", created = 0 }), Ask:new({ id = "0", session = "x", state = "pending", created = 0 }) }
	check("next pending", Ask.next_pending(asks, { a }, 5, alive).id == "1")
	check("ask handles permissions", Ask.handles({ hook_event_name = "PermissionRequest", tool_name = "Bash" }))
	check("ask handles questions once", Ask.handles({ hook_event_name = "PreToolUse", tool_name = "AskUserQuestion" }) and not Ask.handles({ hook_event_name = "PermissionRequest", tool_name = "AskUserQuestion" }))
	check("headless agents get questions again on the permission dialog", Ask.handles({ hook_event_name = "PermissionRequest", tool_name = "AskUserQuestion" }, true))
	check("ask skips other tools",not Ask.handles({ hook_event_name = "PreToolUse", tool_name = "Bash" }))
	local v = View:new({ id = "w" })
	check("follow turn", v:follow_item({ id = "a" }, { turn = 3 }) and v.turn == 3)
	check("follow same", not v:follow_item({ id = "a" }, { turn = 3 }))
	check("follow draft", v:follow_item({ id = "a" }, { draft = true }) and v.state == "draft")
	local asking = View:new({ id = "w2" })
	asking:show_ask("q1", "a")
	check("a draft in the thread doesn't take over a pending ask", not asking:follow_item({ id = "a" }, { draft = true }) and asking.state == "ask" and asking.ask == "q1")
	local q = View:new({ id = "q" })
	q:show_ask("7")
	check("leaving a question forgets it", q:follow_item({ id = "a" }, { turn = 1 }) and q.ask == nil and q.state == "answer")
	check("question can be reopened", q:follow_item({ id = "a" }, { ask = "7" }) and q.state == "ask" and q.ask == "7")
	local s = View:new({ id = "s" })
	s:request_search(5)
	check("search opens once", s:take_search() and not s:take_search())
	local other = View:new({ id = "o" })
	other:select("reading", 2)
	other:show_ask("9", "asker")
	check("a question selects the agent that asks it", other.agent == "asker" and other.turn == nil and other.state == "ask")
	check("new prompt supersedes asks", Ask.superseded_by("prompt") and Ask.superseded_by("stop") and not Ask.superseded_by("tool"))
end)

test("store update, lock, delete", function()
	local root = vim.fn.tempname()
	local store = make_store(root)
	local changes = 0
	store.on_change = function()
		changes = changes + 1
	end
	store:update(Agent, "s1", function(a)
		a:apply("start", 1)
	end)
	check("persisted", store:get(Agent, "s1").state == "idle")
	store:update(Agent, "s1", function()
		return false
	end)
	check("skip write", changes == 1)
	vim.fn.mkdir(root .. "/workspace/locks/agents-s2", "p")
	vim.uv.fs_utime(root .. "/workspace/locks/agents-s2", 0, 0)
	store:update(Agent, "s2", function(a)
		a:apply("start", 1)
	end)
	check("stale lock broken", store:get(Agent, "s2") ~= nil)
	store:remove(Agent, "s1")
	check("deleted", store:get(Agent, "s1") == nil and #store:all(Agent) == 1)
	local log = nvim.fs.read(root .. "/workspace/events.jsonl") or ""
	check("logged", log:find('"transition"') ~= nil)
	vim.fn.delete(root, "rf")
end)

test("sessions", function()
	local Session = models.Session
	local live = Agent:new({ id = "live", state = "working", root = "/p/.claude/worktrees/x", worktree = "x", name = "busy one" })
	local files = {
		{ id = "live", path = "/c/live.jsonl", mtime = 90 },
		{ id = "old", path = "/c/old.jsonl", mtime = 50 },
		{ id = "away", path = "/c/away.jsonl", mtime = 40 },
	}
	local infos = { ["/c/live.jsonl"] = { cwd = "/p" }, ["/c/old.jsonl"] = { cwd = "/p", title = "old work" }, ["/c/away.jsonl"] = { cwd = "/q" } }
	local list = Session.list({ live }, files, infos, "/p", 3650)
	check("running first, files once, other folders left out", #list == 2 and list[1].running and list[2].id == "old", list)
	check("the panel lists only active sessions", #Session.active({ live }, "/p") == 1 and #Session.active({ live }, "/q") == 0)
	local running, ended = list[1], list[2]
	check("running toggles to end", running:toggle() == "end" and running:can_end())
	check("ended resumes", ended:toggle() == "resume" and ended:needs_resume() and not ended:can_end())
	check("only a working agent interrupts", running:can_interrupt() and not ended:can_interrupt())
	check("search says ended", select(1, ended:search_columns()) == "ended" and select(3, ended:search_columns()) == "p · 1h")
	check("rename writes a custom title", ended:rename_entry("new").customTitle == "new" and ended:rename_entry("old work") == nil)
	check("running sessions stop before delete", running:removal("/c/live.jsonl").stop_first)
	check("delete needs a file", running:removal("") == nil and ended:removal().sidecar == "/c/old")
	local drafting = Session.active({ live }, "/p", 3650, { cwd = "/p" })
	check("a new session's draft lists first", #drafting == 2 and drafting[1].drafting and drafting[1].order < drafting[2].order, drafting)
	check("a draft for an agent or elsewhere lists nothing", #Session.active({ live }, "/p", 3650, { agent = "live", cwd = "/p" }) == 1 and #Session.active({}, "/p", 3650, { cwd = "/q" }) == 0)
	local new = drafting[1]
	check("the draft targets a new session", new:target().agent == nil and new:target().cwd == "/p" and not new:needs_resume() and not new:can_end())
end)

test("thread order is stable", function()
	local Thread = models.Thread
	local agent = Agent:new({ id = "a", state = "working" })
	local t = Transcript.new("a", {})
	t.turns = { { prompt = "first", at = 100, last = 150, reply = {} }, { prompt = "second", at = 200, reply = {} } }
	local log = { { type = "message", at = 210, from_session = "a", to_session = "b", text = "hi" } }
	local function order(now)
		local ids = {}
		for _, item in ipairs(Thread.new({ agent = agent, id = "a", transcript = t, log = log, now = now }).items) do
			table.insert(ids, item.id)
		end
		return table.concat(ids, ",")
	end
	check("newest first by start", order(220) == "mb:2,turna2,turna1", order(220))
	local chat = {
		{ type = "message", at = 150, from_session = "a", to_session = "b", text = "status?" },
		{ type = "message", at = 198, from_session = "b", to_session = "a", text = "done" },
		{ type = "message", at = 210, from_session = "a", to_session = "b", text = "thanks" },
		{ type = "message", at = 212, from_session = "c", to_session = "a", text = "ping" },
	}
	local grouped = Thread.new({ agent = agent, id = "a", transcript = t, log = chat, now = 400 })
	local first = grouped.items[grouped:index_of("mb:1") or 0]
	local second = grouped.items[grouped:index_of("mb:2") or 0]
	check("messages group per turn", first and #first.answered.messages == 1 and second and #second.answered.messages == 2, grouped.items)
	check("a received message belongs to the turn it starts", second and second.answered.messages[1].text == "done" and second.fresh == 198, second)
	check("card shows the last message", second and second.card[2] == "→ thanks", second)
	check("a message the agent hasn't picked up yet waits", grouped:index_of("mc:next") ~= nil)
	check("same order later", order(220) == order(900))
	local reader = Agent:new({ id = "a", state = "done", read_at = 120 })
	local th = Thread.new({ agent = reader, id = "a", transcript = t, log = log, now = 220 })
	check("unread items", th.unread == 1, th.unread)
	reader:mark_read(220)
	check("all read", Thread.new({ agent = reader, id = "a", transcript = t, log = log, now = 220 }).unread == 0)
end)

test("queued messages wait for the turn", function()
	local Thread = models.Thread
	local t = Transcript.new("a", {})
	t.turns = { { prompt = "first", at = 100, reply = {} }, { prompt = "later", at = 120, queued = true, reply = {} } }
	local function cards(agent)
		local out = {}
		for _, item in ipairs(Thread.new({ agent = agent, id = "a", transcript = t, now = 130 }).items) do
			out[item.turn] = item
		end
		return out
	end
	local busy = cards(Agent:new({ id = "a", state = "working", updated = 125 }))
	check("the first turn keeps working", busy[1].working and busy[1].card[1] == "working", busy[1])
	check("the queued message is pending", busy[2].pending and busy[2].card[1] == "pending" and busy[2].text == "later", busy[2])
	local waiting = cards(Agent:new({ id = "a", state = "waiting", updated = 125 }))
	check("the first turn waits", waiting[1].card[1] == "waiting" and waiting[2].pending)
	local done = cards(Agent:new({ id = "a", state = "done", updated = 125 }))
	check("both done when the agent stops", done[1].card[1] == "turn 1" and done[2].card[1] == "turn 2" and not done[2].pending)
	local sender = Agent:new({ id = "a", state = "working", updated = 125 })
	sender:start_sending("third", 129)
	local sent = Thread.new({ agent = sender, id = "a", transcript = t, now = 130 })
	local third = sent.items[sent:index_of("turna3") or 0]
	check("a message sent while busy is pending", third and third.pending and third.card[1] == "pending", third)
	local idle = Agent:new({ id = "a", state = "idle" })
	idle:start_sending("go", 129)
	local started = Thread.new({ agent = idle, id = "a", transcript = Transcript.new("a", {}), now = 130 })
	check("a message to an idle agent works", started.items[1] and started.items[1].working and started.items[1].card[1] == "working", started.items)
	local q = Transcript.new("a", {
		{ k = "p", at = "2026-11-04T10:00:00Z", t = "first" },
		{ k = "e", at = "2026-11-04T10:00:05Z", t = "absorbed" },
		{ k = "e", at = "2026-11-04T10:00:06Z", t = "waiting in line" },
		{ k = "d", at = "2026-11-04T10:00:07Z", t = "absorbed" },
	})
	check("the queue keeps what claude hasn't taken", #q:queued() == 1 and q:queued()[1].prompt == "waiting in line", q.queue)
	local worker = Agent:new({ id = "a", state = "working", updated = 125 })
	worker:start_sending("waiting in line", Transcript.epoch("2026-11-04T10:00:06Z"))
	local queued = Thread.new({ agent = worker, id = "a", transcript = q, now = Transcript.epoch("2026-11-04T10:00:08Z") })
	local line = queued.items[queued:index_of("queuea1") or 0]
	check("a queued message is pending right away", line and line.pending and line.card[1] == "pending", queued.items)
	check("and isn't shown twice", queued:index_of("turna2") == nil, queued.items)
	check("an idle agent has no queue", Thread.new({ agent = Agent:new({ id = "a", state = "done" }), id = "a", transcript = q, now = 0 }):index_of("queuea1") == nil)
	q:add({ k = "d", at = "2026-11-04T10:00:09Z" })
	check("dequeue takes the first", #q:queued() == 0)
end)

test("a busy agent's messages wait their turn", function()
	local Thread, Draft = models.Thread, models.Draft
	local a = Agent:new({ id = "a", state = "working", updated = 100 })
	check("a busy agent holds", Draft.new({ agent = "a" }, "next"):delivery(a) == "hold")
	check("an idle agent takes it", Draft.new({ agent = "a" }, "next"):delivery(Agent:new({ id = "a", state = "done" })) == "message")
	a:hold("second", 110)
	a:hold("third", 111.5)
	check("nothing leaves while working", not a:can_release() and a:release() == nil)
	local t = Transcript.new("a", {})
	t.turns = { { prompt = "first", at = 100, reply = {} } }
	local th = Thread.new({ agent = a, id = "a", transcript = t, now = 120 })
	local held = th.items[th:index_of("outbox" .. a:held()[1].id) or 0]
	check("held messages are pending", held and held.pending and held.outbox == a:held()[1].id and held.card[1] == "pending", th.items)
	a:apply("stop", 130)
	local first = a:release()
	check("the turn ending releases the oldest", first and first.text == "second" and #a:held() == 1)
	local third = a:take(a:held()[1].id)
	check("send now takes a specific one", third and third.text == "third" and a.outbox == nil)
	t.turns = { { prompt = "first", at = 100, last = 120, reply = {} }, { prompt = "second", at = 124, reply = {} } }
	check("a turn's stop counts as seen when it ends before the next turn", t:seen_through(1, 124.2) == 124.2 and t:seen_through(1, 140) == 120)
	check("the latest turn takes the stop", t:seen_through(2, 140) == 140)
end)

test("sdk asks answer the permission callback", function()
	local req = { session = "s", tool = "Bash", input = { command = "ls" }, suggestions = { { type = "addRules" } }, cwd = "/p" }
	local a = Ask.from_sdk(req, "q1", 1)
	check("an sdk ask never goes stale", a.source == "sdk" and not a:is_stale(10000, false))
	check("an unanswered ask denies", a:result().behavior == "deny")
	a:decide("always", 2)
	local r = a:result()
	check("always allow carries the rules", r.behavior == "allow" and r.updatedPermissions == req.suggestions and r.updatedInput.command == "ls", r)
	local d = Ask.from_sdk(req, "q2", 1)
	d:decide("deny", 2)
	check("deny says the user denied", d:result().behavior == "deny" and d:result().message ~= nil)
	local q = Ask.from_sdk({ session = "s", tool = "AskUserQuestion", input = { questions = { { question = "which?" } } } }, "q3", 1)
	q:answer({ ["which?"] = "this" }, 2)
	check("a question returns its answers as input", q.kind == "question" and q:result().updatedInput.answers["which?"] == "this", q:result())
	local w = Ask.from_sdk(req, "q4", 1)
	w:dismiss(2)
	check("a withdrawn ask denies", w:result().behavior == "deny" and w:result().message:match("withdrawn") ~= nil)
	local hook = Ask.from_hook({ session_id = "s", hook_event_name = "PermissionRequest", tool_name = "Bash" }, "h", 1, 1)
	hook:decide("allow", 2)
	check("hook asks keep the hook output", hook.output.hookSpecificOutput.decision.behavior == "allow")
end)

test("the bridge drives daemon sessions from events", function()
	local root = vim.fn.tempname()
	local store = make_store(root)
	local replies = {}
	local bridge = require("workspace.bridge").new(store, function(id, result, err)
		table.insert(replies, { id = id, result = result, err = err })
	end)
	local function hook(event, extra)
		local payload = { session_id = "s1", hook_event_name = event, cwd = root }
		for k, v in pairs(extra or {}) do
			payload[k] = v
		end
		bridge:handle({ id = #replies + 1, op = "hook", payload = payload })
	end
	hook("SessionStart")
	local a = store:get(Agent, "s1")
	check("a daemon session is hosted and headless", a and a.host == "agentd" and a.pane == nil and a.state == "idle", a)
	hook("UserPromptSubmit")
	check("a prompt starts work", store:get(Agent, "s1").state == "working")
	bridge:handle({ id = 50, op = "ask", session = "s1", tool = "Bash", input = { command = "rm x" }, cwd = root, request = "t1" })
	local pending = store:all(Ask)[1]
	check("an ask waits without replying", pending and pending.source == "sdk" and #vim.tbl_filter(function(r)
		return r.id == 50
	end, replies) == 0 and store:get(Agent, "s1").state == "waiting")
	store:update(Ask, pending.id, function(x)
		return x:decide("allow", nvim.clock())
	end)
	bridge:settle(store:get(Ask, pending.id))
	local answered = replies[#replies]
	check("answering replies to the daemon", answered.id == 50 and answered.result.behavior == "allow", answered)
	check("the ask is cleared and work resumes", #store:all(Ask) == 0 and store:get(Agent, "s1").state == "working")
	bridge:handle({ id = 60, op = "ask", session = "s1", tool = "Bash", input = {}, request = "t2" })
	bridge:handle({ op = "cancel", request = "t2" })
	check("a cancelled ask denies", replies[#replies].id == 60 and replies[#replies].result.behavior == "deny")
	hook("Stop")
	check("a stop finishes the turn", store:get(Agent, "s1").state == "done")
	bridge:handle({ op = "runtime", report = { type = "runtime", id = "s1", provider = "claude", event = "verify", model = "claude-opus-5-5" } })
	bridge:handle({ op = "runtime", report = { type = "usage", provider = "claude", windows = { { name = "5h", used = 0.1 } }, extra = true } })
	check("runtime reports land in the store", store:get(models.Runtime, "s1").state == "sdk" and store:get(models.Usage, "claude").extra == true)
	bridge:handle({ op = "sync", sessions = {} })
	local ended = store:get(Agent, "s1").state
	bridge:handle({ op = "started", id = "s1", cwd = root })
	check("a resumed session is idle again", store:get(Agent, "s1").state == "idle")
	bridge:handle({ op = "sync", sessions = {} })
	check("a lost daemon ends its agents and runtimes", ended == "stopped" and store:get(Agent, "s1").state == "stopped" and store:get(models.Runtime, "s1").state == "cli")
	bridge:handle({ id = 70, op = "bogus" })
	check("unknown ops answer with an error", replies[#replies].id == 70 and replies[#replies].err ~= nil)
	vim.fn.delete(root, "rf")
end)

test("the registry leaves hosted agents alone and says when to look again", function()
	local Registry = models.Registry
	local hosted = Agent:new({ id = "h", state = "working", host = "agentd", updated = 100 })
	local reg = Registry.new({ { sessionId = "h", pid = 1, status = "idle", statusUpdatedAt = 101000 } }, function()
		return true
	end)
	check("hosted agents aren't reconciled", not reg:needs_reconcile(hosted) and reg:wait(hosted, 102) == nil)
	local cli = Agent:new({ id = "c", state = "working", updated = 100 })
	local reg2 = Registry.new({ { sessionId = "c", pid = 1, status = "idle", statusUpdatedAt = 101000 } }, function()
		return true
	end)
	local wait = reg2:wait(cli, 102)
	check("an idle that hasn't settled yet asks for one more look", wait and wait > 1.9 and wait <= 2, wait)
	check("after the delay there's nothing to wait for", reg2:wait(cli, 105) == nil)
end)

test("daemon health follows its connection", function()
	local d = models.Daemon:new({ id = "agentd" })
	check("a stopped daemon is healthy", d:health() == nil)
	d:observe("launch", nil, 1)
	check("starting shows", d:health() == "starting" and select(2, d:health()) == "busy")
	d:observe("connect", nil, 2)
	check("up is quiet", d:health() == nil)
	d:observe("bridge_lost", "the bridge gave up", 3)
	check("a lost bridge degrades", d:health() == "bridge down" and select(2, d:health()) == "bad" and d.reason == "the bridge gave up")
	check("reconnecting keeps it degraded", d:observe("connect", nil, 4) and d.state == "degraded")
	d:observe("bridge_back", nil, 5)
	check("a returning bridge clears it", d:health() == nil)
	d:observe("drop", nil, 6)
	check("a dropped connection is down", d:health() == "down")
	d:observe("give_up", "keeps dropping", 7)
	check("giving up fails", d:health() == "failed" and d.reason == "keeps dropping")
	d:observe("launch", nil, 8)
	d:observe("connect", nil, 9)
	d:observe("stop", "no workspace holds agentd", 10)
	check("a clean stop is quiet", d:health() == nil)
end)

test("modes and turns come from events", function()
	local r = models.Runtime.for_agent("m")
	r:observe({ event = "verify", model = "claude-opus-5-5", mode = "auto" }, 1)
	check("auto isn't labelled", r.mode == "auto" and r:mode_label() == nil)
	r:observe({ event = "mode", mode = "plan" }, 2)
	check("a mode change keeps the state", r.state == "sdk" and r:mode_label() == "plan" and r.context == nil)
	local s = models.Session.from_agent(Agent:new({ id = "m", state = "working", root = "/p" }):attach({ runtime = r }), 10)
	check("the card names a non-default mode", s:card()[4].label == "opus · plan")
	local a = Agent:new({ id = "t", state = "idle" })
	a:begin_turn("fix the bar", 100)
	a:apply("prompt", 100)
	local waiting = a:awaiting_turn(Transcript.new("t", {}), 101)
	check("the turn shows before the transcript has it", waiting and waiting.text == "fix the bar", waiting)
	local t = Transcript.new("t", {})
	t.turns = { { prompt = "fix the bar", at = 100, reply = {} } }
	check("once the transcript has it, it's a normal turn", a:awaiting_turn(t, 101) == nil)
	a:apply("stop", 102)
	check("a finished agent waits for nothing", a:awaiting_turn(Transcript.new("t", {}), 103) == nil)
end)

test("todos move from open to sent to done", function()
	local Todo = models.Todo
	local t = Todo.make("ab12", "wire the bar\nsecond line", "/p", "you", 10)
	check("a new todo is open and listed", t.state == "open" and t:is_listed() and t:title() == "wire the bar")
	check("an empty edit changes nothing", not t:edit("", 11) and t.text == "wire the bar\nsecond line")
	check("an edit replaces the text", t:edit("wire the health tab", 11) and t:title() == "wire the health tab")
	check("sending records the agent", t:send("agent-1", 12) and t.state == "sent" and t.agent == "agent-1" and t:tone() == "busy")
	local card = t:card(function(id)
		return id == "agent-1" and "vpn" or "?"
	end, 72)
	check("the card says who has it", card[2] == "todo · from you" and card[3] == "sent to vpn · 1m", card)
	check("the message says how to close it", t:message():match("todo ab12") and t:message():match("todo done ab12"))
	check("finishing hides it", t:finish("done it", 13) and not t:is_listed() and t.note == "done it")
	check("a done todo can't be sent", not t:send("agent-2", 14))
	local list = Todo.listed_in({
		Todo.make("1", "old", "/p", "you", 1),
		Todo.make("2", "new", "/p/sub", "s1", 5),
		Todo.make("3", "elsewhere", "/q", "you", 9),
		t,
	}, "/p")
	check("the list keeps this folder's open todos, newest first", #list == 2 and list[1].id == "2" and list[2].id == "1", list)
end)

test("the todo command adds, lists and finishes", function()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root .. "/repo", "p")
	local env = { XDG_STATE_HOME = root, CLAUDE_CODE_SESSION_ID = "s1" }
	local main = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0]))) .. "/cli/main.lua"
	local function todo(...)
		return vim.system({ "nvim", "--clean", "-l", main, "todo", "-C", root .. "/repo", ... }, { env = env, text = true }):wait()
	end
	local added = todo("add", "check the resume")
	local id = vim.trim(added.stdout or "")
	check("add prints the id", added.code == 0 and #id == 4, added)
	local listed = todo("list")
	check("list shows it", listed.stdout:match(id .. "\topen\tcheck the resume") ~= nil, listed)
	local t = make_store(root):get(models.Todo, id)
	check("an agent's todo is from its session", t and t.from == "s1")
	check("done closes it", todo("done", id, "resumed fine").code == 0 and todo("list").stdout == "")
	check("done on an unknown id fails", todo("done", "zzzz").code ~= 0)
	vim.fn.delete(root, "rf")
end)

test("only idle headless cli sessions move to the sdk", function()
	local Session = models.Session
	local function session(fields, runtime)
		return Session.from_agent(Agent:new(fields):attach({ runtime = runtime }), 10)
	end
	check("an idle headless cli session can move", session({ id = "a", state = "done", root = "/p" }):can_move())
	check("a pane session stays", not session({ id = "b", state = "idle", root = "/p", pane = 4 }):can_move())
	check("a busy session waits", not session({ id = "c", state = "working", root = "/p" }):can_move())
	local sdk = models.Runtime.for_agent("d")
	sdk:observe({ event = "verify" }, 1)
	check("an sdk session is already there", not session({ id = "d", state = "idle", root = "/p" }, sdk):can_move())
end)

test("a prompt counts as received by its text, not its clock", function()
	local t = Transcript.new("x", {})
	t.turns = { { prompt = "I dont like it as a new tab", at = 1000, reply = {} } }
	local a = Agent:new({ id = "x", state = "idle" })
	a:begin_turn("I dont like it as a new tab", 1002.6)
	a:apply("prompt", 1002.6)
	check("a hook that runs late still matches the turn", a:awaiting_turn(t, 1003) == nil)
	a:begin_turn("continue", 1005)
	check("a new prompt waits until the transcript has it", a:awaiting_turn(t, 1006).text == "continue")
	t.turns[2] = { prompt = "continue", at = 1004, reply = {} }
	check("then it's a normal turn", a:awaiting_turn(t, 1006) == nil)
	local old = Transcript.new("x", {})
	old.turns = { { prompt = "continue", at = 100, reply = {} } }
	check("the same text long ago doesn't count", a:awaiting_turn(old, 1006) ~= nil)
	local Registry = models.Registry
	local hosted = Agent:new({ id = "h", state = "idle", host = "agentd", root = "/p/.config" })
	local reg = Registry.new({ { sessionId = "h", pid = 1, status = "idle", name = "config-82" } }, function()
		return true
	end)
	check("a daemon agent picks up its session name", reg:needs_reconcile(hosted) and reg:reconcile(hosted, 10) and hosted:display_name() == "config-82" and hosted.state == "idle")
	check("and then leaves it alone", not reg:needs_reconcile(hosted))
end)

test("a turn set has one card per prompt and at most one active turn", function()
	local Thread, Turn = models.Thread, models.Turn
	local function transcript(turns, queue)
		local t = Transcript.new("a", {})
		t.turns, t.queue = turns, queue or {}
		return t
	end
	local function collect(...)
		local turns, rejected = Turn.collect(...)
		return { entries = turns, rejected = rejected }
	end
	local function sane(set, label)
		local active = Turn.active_in(set.entries)
		check(label .. ": at most one active", #active <= 1, active)
		check(label .. ": no rejected transitions", #set.rejected == 0, set.rejected)
	end
	local working = Agent:new({ id = "a", state = "working", updated = 100 })
	local t1 = transcript({ { prompt = "older", at = 10, reply = {} }, { prompt = "I saw duplicates", at = 50, reply = {} } }, { { text = "I saw duplicates", prompt = "I saw duplicates", at = 49 } })
	local set = collect(t1, working, 60)
	sane(set, "leftover queue entry")
	check("a leftover queue entry for the same prompt is dropped", #set.entries == 2 and set.entries[2].state == "working", set.entries)

	local started = Agent:new({ id = "a", state = "idle" })
	started:begin_turn("new task", 70)
	started:apply("prompt", 70)
	local t2 = transcript({ { prompt = "older", at = 10, reply = {} } })
	set = collect(t2, started, 71)
	sane(set, "started prompt")
	check("a started prompt is the active turn and the last turn is done", set.entries[1].state == "done" and set.entries[2].state == "working" and set.entries[2].source == "sending")
	local before = Thread.new({ agent = started, id = "a", transcript = t2, now = 71 })
	local id_before = before.items[1].id
	t2.turns[2] = { prompt = "new task", at = 70, reply = {} }
	local after = Thread.new({ agent = started, id = "a", transcript = t2, now = 72 })
	check("the card keeps its id when the transcript catches up", after.items[1].id == id_before and after.items[1].working and #after.items == 2, after.items)

	local busy = Agent:new({ id = "a", state = "working", updated = 100 })
	busy:start_sending("after this", 80)
	set = collect(transcript({ { prompt = "current", at = 75, reply = {} } }), busy, 81)
	sane(set, "sent while busy")
	check("a message sent while busy waits behind the active turn", set.entries[1].state == "working" and set.entries[2].state == "pending")

	busy:hold("held one", 82)
	set = collect(transcript({ { prompt = "current", at = 75, reply = {} } }), busy, 83)
	sane(set, "held")
	check("held messages are pending too", set.entries[2].state == "pending" and set.entries[2].source == "held")

	local idle = Agent:new({ id = "a", state = "done" })
	set = collect(t1, idle, 90)
	sane(set, "idle")
	check("an idle agent has nothing active or pending", #Turn.active_in(set.entries) == 0 and #vim.tbl_filter(function(t)
		return t:is_pending()
	end, set.entries) == 0)
end)

test("the conversation shows a todo until something else takes over", function()
	local v = View:new({ id = "w" })
	check("a todo shows from the answer", v:show_todo("t1") and v.state == "todo" and v.todo == "t1")
	check("showing the same todo again changes nothing", not v:show_todo("t1"))
	check("another todo replaces it", v:show_todo("t2") and v.todo == "t2")
	check("the view focuses the todo it shows", v:focus() == "t2")
	check("selecting an agent leaves the todo", v:select("a") and v.state == "answer" and v:focus() == "a")
	v:show_ask("q", "a")
	check("a pending ask isn't replaced by a todo", not v:show_todo("t3") and v.state == "ask")
	local d = View:new({ id = "w2" })
	d:compose({ agent = "a" })
	check("a todo can be looked at while drafting", d:show_todo("t1") and d.state == "todo")
end)

test("review guards", function()
	local r = Review:new({ id = Review.key("/repo"), root = "/repo" })
	local c = r:add({ path = "a.lua", line1 = 1, line2 = 1, text = "fix" }, math.random, 1)
	r:send({ c }, 2, "agent-a")
	check("a sent comment remembers its agent", c.sent_to == "agent-a")
	local ok, why = r:mark_ready("done", "agent-a", 3)
	check("ready is refused while comments are open", not ok and why:match(c.id) and r.state ~= "ready", why)
	local wrong, err = r:resolve(c.id, "fixed it", 4, "agent-b")
	check("another agent can't resolve it", wrong == nil and err:match("another agent") and c.state == "sent", err)
	check("the agent it went to can", r:resolve(c.id, "fixed", 5, "agent-a") and c.state == "resolved")
	local again, err2 = r:resolve(c.id, "fixed twice", 6, "agent-a")
	check("a resolved comment isn't resolved twice", again == nil and err2:match("already resolved") and c.reply == "fixed", err2)
	check("ready works once nothing is open", r:mark_ready("done", "agent-a", 7) and r.state == "ready")
	local busy_ok, busy_why = r:can_approve(true)
	check("approving a busy agent is refused", not busy_ok and busy_why:match("still working"))
	local d = r:add({ path = "b.lua", line1 = 2, text = "and this" }, math.random, 8)
	r:send({ d }, 9, "agent-a")
	local open_ok, open_why = r:can_approve(false)
	check("approving with open comments is refused", not open_ok and open_why:match(d.id))
	check("a comment without a recorded agent stays resolvable", (function()
		local e = r:add({ path = "c.lua", line1 = 3, text = "old" }, math.random, 10)
		r:send({ e }, 11)
		return r:resolve(e.id, "ok", 12, "anyone") ~= nil
	end)())

	local protected = { main = true, master = true, develop = true }
	local function push(cmd, branch)
		return Review.push_block("Bash", { command = cmd }, branch or "feature", protected)
	end
	check("pushing the current feature branch is fine", push("git push") == nil and push("git push -u origin feature") == nil)
	check("pushing while on main is blocked", push("git push", "main") ~= nil and push("git push origin", "main") ~= nil)
	check("pushing to main by name is blocked", push("git push origin main") ~= nil and push("git push origin HEAD:main") ~= nil and push("git push origin +feat:refs/heads/master") ~= nil)
	check("the default branch is protected too", push("git push origin develop") ~= nil)
	check("pushing everything is blocked", push("git push --all origin") ~= nil and push("git push --mirror") ~= nil)
	check("push options and other dirs are understood", push("git -C ../x push -o ci.skip origin main") ~= nil and push("git push -o merge_request.remove_source_branch origin feature") == nil)
	check("force pushing a feature branch is fine", push("git push --force-with-lease origin feature") == nil)
	check("pushes after other commands are seen", push("git add -A && git commit -m x && git push origin main") ~= nil)
	check("mentions aren't pushes", push("echo 'git push origin main'") == nil)
	check("pushes are guarded", Review.guards({ hook_event_name = "PreToolUse", tool_name = "Bash", tool_input = { command = "git push" } }))
	local ctx = { branch = "main", protected = protected, tree = function()
		error("the tree isn't needed for a push")
	end }
	local denied = Review.for_root("/repo"):guard({ hook_event_name = "PreToolUse", tool_name = "Bash", tool_input = { command = "git push" } }, ctx, "review")
	check("the guard denies a push to main without computing the tree", denied and denied.hookSpecificOutput.permissionDecisionReason:match("main"))
end)

test("a todo draft saves a todo instead of starting a session", function()
	local Draft, Session = models.Draft, models.Session
	local new = { todo = true, cwd = "/p" }
	local existing = { todo = "ab12", cwd = "/p" }
	check("a new todo has its own draft per folder", Draft.key(new) == "todo--p" and Draft.key(existing) == "todo-ab12")
	check("a todo draft is saved, not delivered", Draft.new(new, "x"):delivery(nil) == "todo")
	check("a todo draft isn't a new session", not Draft.starts_session(new) and Draft.starts_session({ cwd = "/p" }))
	check("no drafting card for a todo", #Session.active({}, "/p", 10, new) == 0 and #Session.active({}, "/p", 10, { cwd = "/p" }) == 1)
end)

test("agents come with what they own", function()
	local repo = require("workspace.agents")
	local root = vim.fn.tempname()
	local store = make_store(root)
	store:update(Agent, "a", function(a)
		a.state, a.root = "working", "/p"
	end)
	store:update(Agent, "b", function(b)
		b.state, b.root = "idle", "/p"
	end)
	repo.record(store, { type = "runtime", id = "a", provider = "claude", event = "verify", model = "claude-opus-5-5" }, 1)
	repo.record(store, { type = "runtime", id = "a", event = "context", used = 50, window = 100 }, 2)
	repo.record(store, { type = "usage", provider = "claude", windows = { { name = "5h", used = 0.2 } }, extra = true }, 3)
	store:update(Ask, "q1", function(q)
		local fresh = Ask.from_sdk({ session = "a", tool = "Bash", input = {} }, "q1", 4)
		for _, f in ipairs(Ask.fields) do
			q[f] = fresh[f]
		end
	end)
	local a = repo.get(store, "a")
	check("an agent knows its runtime", a:on_sdk() and a:channel() == "sdk" and a:model_label() == "opus" and a:context_fraction() == 0.5)
	check("and its provider's usage", a:plan_label() == "5h 20%" and a:uses_extra())
	check("and its pending asks", #a:pending_asks() == 1 and a:pending_asks()[1].id == "q1")
	local b
	for _, x in ipairs(repo.all(store)) do
		b = x.id == "b" and x or b
	end
	check("an agent without a runtime is on the cli", b and not b:on_sdk() and b:channel() == "attach" and #b:pending_asks() == 0 and b:plan_label() == "5h 20%")
	repo.lose_all_but(store, { a = true }, 5)
	check("a live runtime is kept", repo.get(store, "a"):on_sdk())
	repo.lose_all_but(store, {}, 6)
	check("a lost one falls back", not repo.get(store, "a"):on_sdk())
	check("what an agent owns isn't written into it", store:read(Agent, "a").runtime == nil and store:read(Agent, "a").asks == nil)
	vim.fn.delete(root, "rf")
end)

test("pickers open in the conversation", function()
	local v = models.View:new({ id = "w" })
	check("nothing to pick", v:take_pick() == nil)
	v:request_pick({ kind = "model", agent = "a" }, 5)
	local p = v:take_pick()
	check("the request is taken once", p and p.kind == "model" and p.agent == "a" and p.at == 5 and v:take_pick() == nil, p)
end)

test("runtimes fall back to the cli", function()
	local Runtime, Usage, Session = models.Runtime, models.Usage, models.Session
	local r = Runtime.for_agent("a")
	check("a runtime starts checking", r.state == "checking" and r:channel() == nil)
	r:observe({ event = "verify", model = "opus" }, 1)
	check("a verified plan runs on the sdk", r.state == "sdk" and r:channel() == "sdk" and r:warning() == nil)
	r:observe({ event = "model", model = "claude-haiku-5-5" }, 2)
	check("model changes keep the state", r.state == "sdk" and r:model_label() == "haiku")
	r:observe({ event = "reject", reason = "no subscription" }, 3)
	check("a rejected plan falls back with a warning", r.state == "cli" and r:channel() == nil and r:warning() == "no subscription")
	r:observe({ event = "lose" }, 4)
	check("losing the daemon falls back quietly", r.state == "cli" and r:warning() == nil)
	check("a fallback without a session doesn't leave sdk", not Runtime.for_agent("b"):observe({ event = "bogus" }, 1))
	local u = Usage.for_provider("claude")
	check("no usage, no plan label", u:plan_label() == nil)
	u:observe({ windows = { { name = "5h", used = 0.04 }, { name = "week", used = 0.42 } } }, 1)
	check("the plan label shows the tightest window", u:plan_label() == "week 42%")
	local function session(agent, parts)
		return Session.from_agent(Agent:new(agent):attach(parts or {}), 10)
	end
	local sdk = Runtime.for_agent("x")
	sdk:observe({ event = "verify", model = "claude-opus-5-5" }, 1)
	sdk:observe({ event = "context", used = 68000, window = 200000 }, 2)
	local on_sdk = session({ id = "x", state = "working", root = "/p" }, { runtime = sdk, usage = u })
	local m = on_sdk:card()[4]
	check("an sdk card meters its context", m and m.fraction == 0.34 and m.percent == "34%" and m.label == "week 42% · opus", m)
	check("an sdk card isn't flagged", on_sdk:card()[2] == "p")
	local plain = session({ id = "x", state = "working", root = "/p" }):card()
	check("a headless agent off the sdk is flagged cli by its place", plain[2] == "p · cli" and plain[4] == nil, plain)
	local pane = session({ id = "y", state = "working", root = "/p", pane = 3 })
	check("a terminal agent off the sdk doesn't warn", pane:card()[4] == nil)
	local fallen = Runtime.for_agent("x")
	fallen:observe({ event = "reject", reason = "api key set" }, 3)
	local rejected = session({ id = "x", state = "working", root = "/p" }, { runtime = fallen, usage = u }):card()
	check("a rejected plan shows as cli without a bar", rejected[2] == "p · cli" and rejected[4].fraction == nil and rejected[4].label == "week 42%", rejected)
	local stopped = Session.from_file({ id = "z", path = "/c/z.jsonl", mtime = 1 }, { cwd = "/p" }, 1, 10)
	check("an ended session has no meter", stopped:card()[4] == nil)
end)

test("parallel writers lose nothing", function()
	local root = vim.fn.tempname()
	local jobs = {}
	for _ = 1, 20 do
		table.insert(jobs, vim.system({ "nvim", "--clean", "-l", vim.fs.abspath(arg[0]), "increment", root }))
	end
	for _, j in ipairs(jobs) do
		j:wait()
	end
	local a = make_store(root):get(Agent, "counter")
	check("200 increments", a and a.pid == 200, a and a.pid)
	vim.fn.delete(root, "rf")
end)

test("transcript keeps prompts from other sessions", function()
	local lines = {
		vim.json.encode({ type = "user", isMeta = true, timestamp = "2026-11-04T10:00:00Z", origin = { kind = "peer", name = "lead", body = "you own #900" }, message = { content = "Another Claude session sent a message" } }),
		vim.json.encode({ type = "user", isMeta = true, timestamp = "2026-11-04T10:00:01Z", message = { content = "meta noise" } }),
		vim.json.encode({ type = "assistant", timestamp = "2026-11-04T10:00:02Z", message = { content = { { type = "text", text = "on it" } } } }),
		vim.json.encode({ type = "attachment", timestamp = "2026-11-04T10:00:03Z", attachment = { type = "queued_command", commandMode = "prompt", prompt = "<pasted_content id=\"1\">\nmid-turn note\n</pasted_content>", origin = { kind = "human" } } }),
		vim.json.encode({ type = "attachment", timestamp = "2026-11-04T10:00:04Z", attachment = { type = "queued_command", commandMode = "task-notification", prompt = "<task-notification>x</task-notification>" } }),
		vim.json.encode({ type = "assistant", timestamp = "2026-11-04T10:00:05Z", message = { content = { { type = "text", text = "noted" } } } }),
	}
	local res = vim.system({ "jq", "-cR", Transcript.filter }, { stdin = table.concat(lines, "\n"), text = true }):wait()
	local records = {}
	for line in res.stdout:gmatch("[^\n]+") do
		table.insert(records, vim.json.decode(line))
	end
	local t = Transcript.new("x", records)
	check("two turns", t:count() == 2, t.turns)
	check("mid-turn message is a queued turn", t:turn(2) and t:turn(2).prompt == "mid-turn note" and t:turn(2).queued and t:turn(2).reply[1] == "noted", t:turn(2))
	check("peer body is the prompt", t:turn(1) and t:turn(1).prompt == "you own #900", t:turn(1))
	check("sender kept", t:turn(1) and t:turn(1).from == "lead", t:turn(1))
	check("reply attached", t:turn(1) and t:turn(1).reply[1] == "on it", t:turn(1))
	check("card line of a reply comment", Transcript.card_line("On your reply:\n\n> quoted\nwhy this?") == "why this?")
	local parts = Review.parse_prompt("On your reply:\n\n> said this\nwhy?\n\nReview comments on the current changes:\n\n[5ce2] a.lua:3\n> x = 1\n> \nuse constants\n\nsecond paragraph\n\n" .. Review.instructions_lead .. ", mark it resolved")
	check("prompt parts", parts and #parts == 4, parts)
	check("reply comment parsed", parts and parts[2].quote[1] == "said this" and parts[2].text == "why?" and not parts[2].label, parts)
	check("review comment parsed", parts and parts[4].label == "[5ce2] a.lua:3" and #parts[4].quote == 2 and parts[4].text == "use constants\n\nsecond paragraph", parts)
	check("plain prompt not parsed", Review.parse_prompt("hello\n\n> quote") == nil)
	check("card line of review comments", Transcript.card_line("Review comments on the current changes:\n\n[5ce2] a.lua:3\n> code\nuse constants") == "use constants")
end)

if #failures > 0 then
	io.write(("%d/%d checks failed\n"):format(#failures, count))
	for _, f in ipairs(failures) do
		io.write("  ✗ " .. f .. "\n")
	end
	os.exit(1)
end
io.write(("%d checks passed\n"):format(count))
