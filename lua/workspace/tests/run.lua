local base = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0]))))
package.path = base .. "/?.lua;" .. base .. "/?/init.lua;" .. package.path

local nvim = require("workspace.shared.adapters.nvim")
local Provider = require("workspace.shared.providers").current()
local function raw(moment, fields)
	return Provider.raw(moment, fields)
end
local function event(moment, fields)
	return Provider.session_event(Provider.raw(moment, fields))
end
local paths = require("workspace.shared.state.paths")
local store_mod = require("workspace.shared.state.store")
local Miles = require("workspace.legio.domain.miles")
local Question = require("workspace.conversations.domain.question")
local AgentdStatus = require("workspace.legio.domain.agentd_status")
local DiffProgress = require("workspace.workflow.domain.diff_progress")
local Draft = require("workspace.conversations.domain.draft")
local Expeditio = require("workspace.workflow.domain.expeditio")
local expeditio_dto_mapper = require("workspace.workflow.application.mappers.expeditio_dto_mapper")
local expeditio_view_mapper = require("workspace.workflow.presentation.mappers.expeditio_view_mapper")
local MergeRequest = require("workspace.workflow.domain.merge_request")
local MilesSessionList = require("workspace.legio.domain.miles_session_list")
local Resource = require("workspace.infra.domain.resource")
local Review = require("workspace.workflow.domain.review")
local MilesProcess = require("workspace.legio.domain.miles_process")
local Contubernium = require("workspace.legio.domain.contubernium")
local Thread = require("workspace.conversations.domain.thread")
local Mandatum = require("workspace.workflow.domain.mandatum")
local Transcript = require("workspace.conversations.domain.transcript")
local Turn = require("workspace.conversations.domain.turn")
local Usage = require("workspace.legio.domain.usage")
local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")
local Workspace = require("workspace.workbench.domain.workspace")

local miles_dto_mapper = require("workspace.legio.application.mappers.miles_dto_mapper")
local miles_view_mapper = require("workspace.legio.presentation.mappers.miles_view_mapper")
local composition_root = require("workspace.composition_root")
local MilesRepository = require("workspace.legio.infrastructure.outbound.filesystem.miles_repository")
local ContuberniumRepository = require("workspace.legio.infrastructure.outbound.filesystem.contubernium_repository")
local ProcessReportCommand = require("workspace.legio.application.commands.process_report_command")
local SessionEventCommand = require("workspace.legio.application.commands.session_event_command")

local function miles_row(miles, now, name)
	return miles_view_mapper.to_miles_row(miles_dto_mapper.to_miles_dto(miles, now or os.time()), name)
end

local function active_rows(milites, folder, now, draft, contubernia)
	local dtos = miles_dto_mapper.to_milites_dtos(Miles.running_in(milites, folder), now or os.time())
	return miles_view_mapper.to_active_rows(dtos, folder, draft, Draft.starts_session(draft) and Draft.key(draft) or nil, contubernia)
end

local function card_lines(row, counts, mr, now)
	return miles_view_mapper.to_card_lines(row, counts, mr and mr:card_lines(now or os.time()))
end

local function make_store(root)
	return store_mod.new({ paths = paths.new(vim.env.HOME, root), fs = nvim.fs, json = nvim.json, clock = nvim.clock, random = math.random })
end

if arg[1] == "increment" then
	local store = make_store(arg[2])
	for _ = 1, 10 do
		store:update(Miles, "counter", function(a)
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
	local a = Miles:new({ id = "abcdef1234" })
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
	check("start", event("start").transition == "start")
	check("question", event("before_tool", { tool_name = "AskUserQuestion" }).transition == "ask")
	check("other pre is work", event("before_tool", { tool_name = "Bash" }).transition == "tool")
	local busy = Miles:new({ id = "busy", state = "working", updated = 100 })
	busy:note_tool("before_tool", "Bash", { command = "npm test", description = "Run the tests" }, 100)
	check("shows the running tool", busy:progress(130) == "Bash: Run the tests · 30s", busy:progress(130))
	busy:note_tool("after_tool", "Bash", { command = "npm test" }, 200)
	check("last tool between tools", busy:progress(212) == "last Bash: npm test · 12s", busy:progress(212))
	check("thinking before any tool", Miles:new({ id = "t", state = "working", updated = 5 }):progress(9) == "thinking · 4s")
	local text, tone = busy:progress(200 + Miles.quiet_after + 60)
	check("quiet for a while", text == "quiet for 6m" and tone == "bad", text)
	busy:note_tool("before_tool", "mcp__plugin_gitlab_gitlab__get_job", { url = "x" }, 300)
	check("mcp tools are short", busy.doing.label == "get_job: x", busy.doing)
	busy:apply("stop", 310)
	check("a stop clears it", busy.doing == nil and busy:progress(320) == nil)
	check("permission note", event("notice", { notification_type = "permission_prompt" }).transition == "ask")
	check("idle note", event("notice", { notification_type = "idle_prompt" }).transition == nil)
end)

test("agent reconcile and status", function()
	local a = Miles:new({ id = "s1", state = "working", updated = 0 })
	check("settles when idle", a:reconcile({ status = "idle" }, true, 10) and a.state == "idle")
	check("ends when gone", a:reconcile(nil, false, 11) and a.state == "stopped")
	check("revives", a:reconcile({ status = "idle" }, true, 12) and a.state == "idle")
	local b = Miles:new({ id = "s2", state = "working", updated = 100 })
	check("registry older than the last hook is ignored", not b:reconcile({ status = "waiting", statusUpdatedAt = 99000 }, true, 101))
	check("dialog open in the terminal", b:reconcile({ status = "waiting", statusUpdatedAt = 100500 }, true, 101) and b.state == "waiting")
	check("question held by the workspace stays", not b:reconcile({ status = "busy", statusUpdatedAt = 102000 }, true, 103, true) and b.state == "waiting")
	check("answered in the terminal", b:reconcile({ status = "busy", statusUpdatedAt = 102000 }, true, 103) and b.state == "working")
	local named = Miles:new({ id = "n", state = "idle", name = "6ec84ec0" })
	check("picks up the provider's name for the session", named:reconcile({ status = "idle", name = "singular span subjects" }, true, 10) and named:display_name() == "singular span subjects")
	check("same name changes nothing", not named:reconcile({ status = "idle", name = "singular span subjects" }, true, 11))
	check("interrupt settles after a pause",not b:reconcile({ status = "idle", statusUpdatedAt = 104000 }, true, 105) and b:reconcile({ status = "idle", statusUpdatedAt = 104000 }, true, 108) and b.state == "idle")
	b:apply("stop", 109)
	check("stop after settling still marks done", b.state == "done")
	local c = Miles:new({ id = "s3", state = "working" })
	c:receive_message(1)
	c:apply("prompt", 1)
	check("message status is the state", c:status() == "working")
	local r = Miles:new({ id = "r", state = "idle", updated = 10 })
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
	local mcp = event("before_tool", { tool_name = mr, tool_input = { project_id = "x", title = "t" } })
	check("the hook guards mr tools only", Review.guards(mcp) and not Review.guards(event("before_tool", { tool_name = "Read" })))
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
	local early = Review:new({ id = Review.key("/early"), root = "/early" })
	check("you can approve work the agent never marked ready", early:approve("s", 5, "t0") and early.state == "approved" and early.approved.tree == "t0")
	check("but not while its agent is still working", not Review:new({ id = "x", root = "/x" }):approve("s", 5, "t0", true))
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
	local a = Question.from_session_event(event("permission", { session_id = "s", tool_name = "Bash", tool_input = { command = "ls" }, permission_suggestions = { { type = "addRules", rules = { { toolName = "Bash", ruleContent = "ls" } } } } }), "1", 5, 0)
	check("permission kind", a.kind == "permission" and #a:permission_choices() == 3)
	check("summary", a:summary() == "Bash: ls")
	a:decide("always", 1)
	check("always output", a.state == "answered" and a.output.hookSpecificOutput.decision.updatedPermissions ~= nil)
	check("answer text", a:answer_text() == "always allowed")
	local q = Question.from_session_event(event("before_tool", { session_id = "s", tool_name = "AskUserQuestion", tool_input = { questions = { { question = "which?", options = { { label = "a" } } } } } }), "2", 5, 0)
	q:answer({ ["which?"] = "a" }, 1)
	check("question output", q.output.hookSpecificOutput.permissionDecision == "allow" and q:answer_text() == "a")
	check("stale", Question:new({ state = "pending", created = 0 }):is_stale(1000, true))
	local shown = Question:new({ id = "3" })
	check("a new question is unseen", shown:is_unseen() and shown:is_pending())
	check("a pane shows it", shown:show(1) and shown.state == "shown" and not shown:is_unseen() and shown:is_pending())
	check("a shown question can still be answered", shown:answer({}, 2) and shown.state == "answered")
	local unseen = Question:new({ id = "4" })
	check("an unseen question goes back to the terminal", unseen:dismiss(1) and unseen.decision == "terminal" and not unseen:show(2))
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
	local scoped = Workspace:new({ id = "3", root = "/code/app" })
	check("contains its root and below", scoped:contains("/code/app") and scoped:contains("/code/app/web"))
	check("ignores siblings", not scoped:contains("/code/app2") and not scoped:contains("/code/automator"))
	check("contains nothing without a root", not Workspace:new({ id = "4" }):contains("/code/app"))
	check("missing", #w:missing(function()
		return false
	end) == 4)
	local placed = Workspace:new({ id = "5", panes = { sidebar = "1", editor = "2" } })
	local dead = function()
		return false
	end
	check("missing lists unplaced and dead roles", vim.deep_equal(placed:missing(dead), { "sidebar", "conversation", "editor", "docker" }))
	check("keep_closed skips dead roles", vim.deep_equal(placed:missing(dead, true), { "conversation", "docker" }))
end)

test("view modes", function()
	local v = ConversationScreen:new({ id = "1" })
	v:compose({ cwd = "/x" })
	check("draft", v.state == "draft")
	v:show_ask("a1")
	v:settle_ask(true)
	check("back to draft", v.state == "draft")
	v:finish_compose()
	check("answer", v.state == "answer" and v.draft == nil)
end)

test("rules live in the models", function()
	local alive = function(pid)
		return pid ~= 2
	end
	local reg = MilesSessionList.new({ { sessionId = "a", pid = 1, status = "idle", cwd = "/p" }, { sessionId = "b", pid = 2 }, { sessionId = "c", pid = 3, parkedJobId = "x" }, { sessionId = "d", pid = 4, name = "dee", status = "busy", cwd = "/q" } }, alive)
	local a = Miles:new({ id = "a", state = "working", updated = 0, root = "/p" })
	check("needs reconcile", reg:needs_reconcile(a) and reg:reconcile(a, 10) and a.state == "idle")
	local gone = Miles:new({ id = "b", state = "idle" })
	check("dead ends", reg:reconcile(gone, 10) and gone.state == "stopped")
	local untracked = reg:untracked({ a = true })
	check("untracked skips parked and dead", #untracked == 1 and untracked[1].sessionId == "d", untracked)
	local d = Miles:new({ id = "d" })
	MilesSessionList.adopt(d, untracked[1], 11)
	check("adopt busy", d.state == "working" and d.root == "/q")
	check("recipient by name", reg:recipient("dee [x]").sessionId == "d")
	check("recipient by socket", reg:recipient("uds:/tmp/cc-socks/1.sock").sessionId == "a")
	a:bind_pane("23", false)
	check("pane channel", a:channel() == "pane" and a.pane == 23)
	a:bind_pane("23", true)
	check("attach channel", a:channel() == "attach")
	check("relocates", Miles.relocates_on("prompt") and not Miles.relocates_on("tool"))
	check("open starts nothing", Workspace.launch("workspace") == nil)
	check("launch resume", Workspace.launch("session:abc").resume == "abc")
	local picked, list = Review.recipient({ a, d }, "/p", nil)
	check("recipient here", picked == a)
	picked, list = Review.recipient({ a, d }, "/none", nil)
	check("recipient choose", picked == nil and #list == 2)
	local b = Miles:new({ id = "b", state = "working", root = "/p", name = "bee" })
	picked, list = Review.recipient({ a, b, d }, "/p", "b")
	check("two agents in the repo ask, the viewed one first", picked == nil and #list == 2 and list[1] == b, list)
	local asks = { Question:new({ id = "2", session = "a", state = "pending", created = 0 }), Question:new({ id = "1", session = "a", state = "pending", created = 0 }), Question:new({ id = "0", session = "x", state = "pending", created = 0 }) }
	check("next pending", Question.next_pending(asks, { a }, 5, alive).id == "1")
	check("ask handles permissions", Question.handles(event("permission", { tool_name = "Bash" })))
	check("ask handles questions once", Question.handles(event("before_tool", { tool_name = "AskUserQuestion" })) and not Question.handles(event("permission", { tool_name = "AskUserQuestion" })))
	check("headless agents get questions again on the permission dialog", Question.handles(event("permission", { tool_name = "AskUserQuestion" }), true))
	check("ask skips other tools",not Question.handles(event("before_tool", { tool_name = "Bash" })))
	local v = ConversationScreen:new({ id = "w" })
	check("follow turn", v:follow_item({ id = "a" }, { turn = 3 }) and v.turn == 3)
	check("follow same", not v:follow_item({ id = "a" }, { turn = 3 }))
	check("follow draft", v:follow_item({ id = "a" }, { draft = true }) and v.state == "draft")
	local asking = ConversationScreen:new({ id = "w2" })
	asking:show_ask("q1", "a")
	check("a draft in the thread doesn't take over a pending ask", not asking:follow_item({ id = "a" }, { draft = true }) and asking.state == "ask" and asking.ask == "q1")
	local q = ConversationScreen:new({ id = "q" })
	q:show_ask("7")
	check("leaving a question forgets it", q:follow_item({ id = "a" }, { turn = 1 }) and q.ask == nil and q.state == "answer")
	check("question can be reopened", q:follow_item({ id = "a" }, { ask = "7" }) and q.state == "ask" and q.ask == "7")
	local s = ConversationScreen:new({ id = "s" })
	s:request_search(5)
	check("search opens once", s:take_search() and not s:take_search())
	local other = ConversationScreen:new({ id = "o" })
	other:select("reading", 2)
	other:show_ask("9", "asker")
	check("a question selects the agent that asks it", other.agent == "asker" and other.turn == nil and other.state == "ask")
	check("new prompt supersedes asks", Question.superseded_by("prompt") and Question.superseded_by("stop") and not Question.superseded_by("tool"))
end)

test("a question waits only when a workspace can show it", function()
	local inquiry = require("workspace.conversations.application.inquiry")
	local store = make_store(vim.fn.tempname())
	check("plain wezterm, no workspace", not inquiry.has_viewer(store, { "/code/app" }))
	store:put(Workspace, Workspace:new({ id = "w", root = "/code/app", panes = { editor = 1, sidebar = 2 } }))
	check("a workspace without a conversation pane", not inquiry.has_viewer(store, { "/code/app" }))
	store:put(Workspace, Workspace:new({ id = "w", root = "/code/app", panes = { editor = 1, sidebar = 2, conversation = 3 } }))
	check("an agent inside the workspace", inquiry.has_viewer(store, { "/code/app/sub" }))
	check("an agent in another folder", not inquiry.has_viewer(store, { "/code/other" }))
end)

test("store update, lock, delete", function()
	local root = vim.fn.tempname()
	local store = make_store(root)
	local changes = 0
	store.on_change = function()
		changes = changes + 1
	end
	store:update(Miles, "s1", function(a)
		a:apply("start", 1)
	end)
	check("persisted", store:get(Miles, "s1").state == "idle")
	store:update(Miles, "s1", function()
		return false
	end)
	check("skip write", changes == 1)
	vim.fn.mkdir(root .. "/workspace/locks/agents-s2", "p")
	vim.uv.fs_utime(root .. "/workspace/locks/agents-s2", 0, 0)
	store:update(Miles, "s2", function(a)
		a:apply("start", 1)
	end)
	check("stale lock broken", store:get(Miles, "s2") ~= nil)
	store:remove(Miles, "s1")
	check("deleted", store:get(Miles, "s1") == nil and #store:all(Miles) == 1)
	local log = nvim.fs.read(root .. "/workspace/events.jsonl") or ""
	check("logged", log:find('"transition"') ~= nil)
	vim.fn.delete(root, "rf")
end)

test("sessions", function()
	local live = Miles:new({ id = "live", state = "working", root = "/p/.worktrees/x", worktree = "x", name = "busy one" })
	local files = {
		{ id = "live", path = "/c/live.jsonl", mtime = 90 },
		{ id = "old", path = "/c/old.jsonl", mtime = 50 },
		{ id = "away", path = "/c/away.jsonl", mtime = 40 },
	}
	local infos = { ["/c/live.jsonl"] = { cwd = "/p" }, ["/c/old.jsonl"] = { cwd = "/p", title = "old work" }, ["/c/away.jsonl"] = { cwd = "/q" } }
	local list = miles_view_mapper.to_session_list(active_rows({ live }, "/p", 3650), files, infos, "/p", 3650)
	check("running first, files once, other folders left out", #list == 2 and list[1].running and list[2].id == "old", list)
	check("the panel lists only active sessions", #active_rows({ live }, "/p") == 1 and #active_rows({ live }, "/q") == 0)
	local running, ended = list[1], list[2]
	check("running toggles to end", running.toggle == "end" and not running.cannot_end)
	check("ended resumes", ended.toggle == "resume" and ended.needs_resume and ended.cannot_end ~= nil)
	check("only a working agent interrupts", not running.cannot_interrupt and ended.cannot_interrupt ~= nil)
	check("search says ended", ended.search_word == "ended" and ended.search_detail == "p · 1h")
	check("rename writes a custom title", miles_view_mapper.to_new_title(ended, "new") == "new" and miles_view_mapper.to_new_title(ended, "old work") == nil)
	check("running sessions stop before delete", miles_view_mapper.to_removal_plan(running, "/c/live.jsonl").stop_first)
	check("delete needs a file", miles_view_mapper.to_removal_plan(running, "") == nil and miles_view_mapper.to_removal_plan(ended).sidecar == "/c/old")
	local drafting = active_rows({ live }, "/p", 3650, { cwd = "/p" })
	check("a new session's draft lists first", #drafting == 2 and drafting[1].drafting and drafting[1].order < drafting[2].order, drafting)
	check("a draft for an agent or elsewhere lists nothing", #active_rows({ live }, "/p", 3650, { agent = "live", cwd = "/p" }) == 1 and #active_rows({}, "/p", 3650, { cwd = "/q" }) == 0)
	local new = drafting[1]
	check("the draft targets a new session", new.target.agent == nil and new.target.cwd == "/p" and not new.needs_resume and new.cannot_end ~= nil)
end)

test("thread order is stable", function()
	local agent = Miles:new({ id = "a", state = "working" })
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
	local reader = Miles:new({ id = "a", state = "done", read_at = 120 })
	local th = Thread.new({ agent = reader, id = "a", transcript = t, log = log, now = 220 })
	check("unread items", th.unread == 1, th.unread)
	reader:mark_read(220)
	check("all read", Thread.new({ agent = reader, id = "a", transcript = t, log = log, now = 220 }).unread == 0)
end)

test("queued messages wait for the turn", function()
	local t = Transcript.new("a", {})
	t.turns = { { prompt = "first", at = 100, reply = {} }, { prompt = "later", at = 120, queued = true, reply = {} } }
	local function cards(agent)
		local out = {}
		for _, item in ipairs(Thread.new({ agent = agent, id = "a", transcript = t, now = 130 }).items) do
			out[item.turn] = item
		end
		return out
	end
	local busy = cards(Miles:new({ id = "a", state = "working", updated = 125 }))
	check("the first turn keeps working", busy[1].working and busy[1].card[1] == "working", busy[1])
	check("the queued message is pending", busy[2].pending and busy[2].card[1] == "pending" and busy[2].text == "later", busy[2])
	local waiting = cards(Miles:new({ id = "a", state = "waiting", updated = 125 }))
	check("the first turn waits", waiting[1].card[1] == "waiting" and waiting[2].pending)
	local done = cards(Miles:new({ id = "a", state = "done", updated = 125 }))
	check("both done when the agent stops", done[1].card[1] == "turn 1" and done[2].card[1] == "turn 2" and not done[2].pending)
	local sender = Miles:new({ id = "a", state = "working", updated = 125 })
	sender:start_sending("third", 129)
	local sent = Thread.new({ agent = sender, id = "a", transcript = t, now = 130 })
	local third = sent.items[sent:index_of("turna3") or 0]
	check("a message sent while busy is pending", third and third.pending and third.card[1] == "pending", third)
	local idle = Miles:new({ id = "a", state = "idle" })
	idle:start_sending("go", 129)
	local started = Thread.new({ agent = idle, id = "a", transcript = Transcript.new("a", {}), now = 130 })
	check("a message to an idle agent works", started.items[1] and started.items[1].working and started.items[1].card[1] == "working", started.items)
	local q = Transcript.new("a", {
		{ k = "p", at = "2026-11-04T10:00:00Z", t = "first" },
		{ k = "e", at = "2026-11-04T10:00:05Z", t = "absorbed" },
		{ k = "e", at = "2026-11-04T10:00:06Z", t = "waiting in line" },
		{ k = "d", at = "2026-11-04T10:00:07Z", t = "absorbed" },
	})
	check("the queue keeps what the provider hasn't taken", #q:queued() == 1 and q:queued()[1].prompt == "waiting in line", q.queue)
	local worker = Miles:new({ id = "a", state = "working", updated = 125 })
	worker:start_sending("waiting in line", Transcript.epoch("2026-11-04T10:00:06Z"))
	local queued = Thread.new({ agent = worker, id = "a", transcript = q, now = Transcript.epoch("2026-11-04T10:00:08Z") })
	local line = queued.items[queued:index_of("queuea1") or 0]
	check("a queued message is pending right away", line and line.pending and line.card[1] == "pending", queued.items)
	check("and isn't shown twice", queued:index_of("turna2") == nil, queued.items)
	check("an idle agent has no queue", Thread.new({ agent = Miles:new({ id = "a", state = "done" }), id = "a", transcript = q, now = 0 }):index_of("queuea1") == nil)
	q:add({ k = "d", at = "2026-11-04T10:00:09Z" })
	check("dequeue takes the first", #q:queued() == 0)
end)

test("a busy agent's messages wait their turn", function()
	local a = Miles:new({ id = "a", state = "working", updated = 100 })
	check("a busy agent holds", Draft.new({ agent = "a" }, "next"):delivery(a) == "hold")
	check("an idle agent takes it", Draft.new({ agent = "a" }, "next"):delivery(Miles:new({ id = "a", state = "done" })) == "message")
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
	local a = Question.from_sdk(req, "q1", 1)
	check("an sdk ask never goes stale", a.source == "sdk" and not a:is_stale(10000, false))
	check("an unanswered ask denies", a:result().behavior == "deny")
	a:decide("always", 2)
	local r = a:result()
	check("always allow carries the rules", r.behavior == "allow" and r.updatedPermissions == req.suggestions and r.updatedInput.command == "ls", r)
	local d = Question.from_sdk(req, "q2", 1)
	d:decide("deny", 2)
	check("deny says the user denied", d:result().behavior == "deny" and d:result().message ~= nil)
	local q = Question.from_sdk({ session = "s", tool = "AskUserQuestion", input = { questions = { { question = "which?" } } } }, "q3", 1)
	q:answer({ ["which?"] = "this" }, 2)
	check("a question returns its answers as input", q.kind == "question" and q:result().updatedInput.answers["which?"] == "this", q:result())
	local w = Question.from_sdk(req, "q4", 1)
	w:dismiss(2)
	check("a withdrawn ask denies", w:result().behavior == "deny" and w:result().message:match("withdrawn") ~= nil)
	local hook = Question.from_session_event(event("permission", { session_id = "s", tool_name = "Bash" }), "h", 1, 1)
	hook:decide("allow", 2)
	check("hook asks keep the hook output", hook.output.hookSpecificOutput.decision.behavior == "allow")
end)

test("the bridge drives daemon sessions from events", function()
	local root = vim.fn.tempname()
	local store = make_store(root)
	local replies = {}
	local handler = require("workspace.legio.infrastructure.inbound.agentd_bridge").new(store, function(id, result, err)
		table.insert(replies, { id = id, result = result, err = err })
	end)
	local function hook(event, extra)
		local payload = raw(event, { session_id = "s1", cwd = root })
		for k, v in pairs(extra or {}) do
			payload[k] = v
		end
		handler:dispatch({ id = #replies + 1, op = "hook", payload = payload })
	end
	hook("SessionStart")
	local a = store:get(Miles, "s1")
	check("a daemon session is hosted and headless", a and a.host == "agentd" and a.pane == nil and a.state == "idle", a)
	hook("UserPromptSubmit")
	check("a prompt starts work", store:get(Miles, "s1").state == "working")
	handler:dispatch({ id = 50, op = "ask", session = "s1", tool = "Bash", input = { command = "rm x" }, cwd = root, request = "t1" })
	local pending = store:all(Question)[1]
	check("an ask waits without replying", pending and pending.source == "sdk" and #vim.tbl_filter(function(r)
		return r.id == 50
	end, replies) == 0 and store:get(Miles, "s1").state == "waiting")
	store:update(Question, pending.id, function(x)
		return x:decide("allow", nvim.clock())
	end)
	handler:reply_if_answered(pending.id)
	local answered = replies[#replies]
	check("answering replies to the daemon", answered.id == 50 and answered.result.behavior == "allow", answered)
	check("the ask is cleared and work resumes", #store:all(Question) == 0 and store:get(Miles, "s1").state == "working")
	handler:dispatch({ id = 60, op = "ask", session = "s1", tool = "Bash", input = {}, request = "t2" })
	handler:dispatch({ op = "cancel", request = "t2" })
	check("a cancelled ask denies", replies[#replies].id == 60 and replies[#replies].result.behavior == "deny")
	hook("Stop")
	check("a stop finishes the turn", store:get(Miles, "s1").state == "done")
	handler:dispatch({ op = "runtime", report = { type = "runtime", id = "s1", provider = Provider.name, event = "verify", model = Provider.name .. "-opus-5-5" } })
	handler:dispatch({ op = "runtime", report = { type = "usage", provider = Provider.name, windows = { { name = "5h", used = 0.1 } }, extra = true } })
	check("runtime reports land in the store", store:get(MilesProcess, "s1").state == "sdk" and store:get(Usage, Provider.name).extra == true)
	handler:dispatch({ op = "sync", sessions = {} })
	local ended = store:get(Miles, "s1").state
	handler:dispatch({ op = "started", id = "s1", cwd = root })
	check("a resumed session is idle again", store:get(Miles, "s1").state == "idle")
	handler:dispatch({ op = "sync", sessions = {} })
	check("a lost daemon ends its agents and runtimes", ended == "stopped" and store:get(Miles, "s1").state == "stopped" and store:get(MilesProcess, "s1").state == "cli")
	handler:dispatch({ id = 70, op = "bogus" })
	check("unknown ops answer with an error", replies[#replies].id == 70 and replies[#replies].err ~= nil)
	vim.fn.delete(root, "rf")
end)

test("a booting agentd forgets agents and runtimes of sessions it won't resume", function()
	local root = vim.fn.tempname()
	local store = make_store(root)
	local handler = require("workspace.legio.infrastructure.inbound.agentd_bridge").new(store, function() end)
	for _, id in ipairs({ "gone", "kept", "cli" }) do
		handler:dispatch({ op = "runtime", report = { type = "runtime", id = id, provider = Provider.name, event = "verify" } })
	end
	handler:dispatch({ op = "started", id = "kept", cwd = root })
	handler:dispatch({ op = "started", id = "gone", cwd = root })
	store:update(Miles, "ended", function(a)
		a:apply("end", nvim.clock())
	end)
	store:update(Miles, "cli", function(a)
		a:apply("start", nvim.clock())
	end)
	handler:dispatch({ op = "sync", sessions = {} })
	check("a resync without a saved list removes nothing", #store:all(MilesProcess) == 3 and store:get(Miles, "gone").state == "stopped")
	handler:dispatch({ op = "sync", sessions = {}, saved = { "kept" } })
	check("an ended session that isn't saved loses its runtime", store:get(MilesProcess, "gone") == nil)
	check("a session agentd will resume keeps its runtime", store:get(MilesProcess, "kept") ~= nil and store:get(Miles, "kept").state == "stopped")
	check("an agent still running in a terminal keeps its runtime", store:get(MilesProcess, "cli") ~= nil)
	check("a stopped terminal agent is left alone", store:get(Miles, "ended") ~= nil)
	check("a stopped agentd agent that won't be resumed is removed", store:get(Miles, "gone") == nil)
	vim.fn.delete(root, "rf")
end)

test("the registry leaves hosted agents alone and says when to look again", function()
	local hosted = Miles:new({ id = "h", state = "working", host = "agentd", updated = 100 })
	local reg = MilesSessionList.new({ { sessionId = "h", pid = 1, status = "idle", statusUpdatedAt = 101000 } }, function()
		return true
	end)
	check("hosted agents aren't reconciled", not reg:needs_reconcile(hosted) and reg:wait(hosted, 102) == nil)
	local cli = Miles:new({ id = "c", state = "working", updated = 100 })
	local reg2 = MilesSessionList.new({ { sessionId = "c", pid = 1, status = "idle", statusUpdatedAt = 101000 } }, function()
		return true
	end)
	local wait = reg2:wait(cli, 102)
	check("an idle that hasn't settled yet asks for one more look", wait and wait > 1.9 and wait <= 2, wait)
	check("after the delay there's nothing to wait for", reg2:wait(cli, 105) == nil)
end)

test("daemon health follows its connection", function()
	local d = AgentdStatus:new({ id = "agentd" })
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
	local r = MilesProcess.for_miles("m")
	r:observe({ event = "verify", model = Provider.name .. "-opus-5-5", mode = "auto" }, 1)
	check("auto isn't labelled", r.mode == "auto" and r:mode_label() == nil)
	r:observe({ event = "mode", mode = "plan" }, 2)
	check("a mode change keeps the state", r.state == "sdk" and r:mode_label() == "plan" and r.context == nil)
	local s = miles_row(Miles:new({ id = "m", state = "working", root = "/p" }):hydrate({ runtime = r }), 10)
	check("the card names a non-default mode", card_lines(s)[4].label == "opus · plan")
	local a = Miles:new({ id = "t", state = "idle" })
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

test("a session sent todos is titled after them", function()
	local function make(id, title, epic)
		return Mandatum.make(id, { title = title, description = "d", criteria = {} }, "/p", "you", 1, epic)
	end
	local epics = { e1 = "gitlab review states" }
	local function epic_title(id)
		return epics[id]
	end
	local one, two, other = make("a", "show changes requested", "e1"), make("b", "colour the mr label", "e1"), make("c", "fix the bar", "e2")
	check("one todo names it", Mandatum.session_title({ one }, epic_title) == "show changes requested")
	check("todos from one epic take its title", Mandatum.session_title({ one, two }, epic_title) == "gitlab review states")
	check("mixed epics name the first", Mandatum.session_title({ one, other }, epic_title) == "show changes requested and 1 more", Mandatum.session_title({ one, other }, epic_title))
end)

test("todos move from open to sent to done", function()
	local t = Mandatum.make("ab12", "wire the bar\nsecond line", "/p", "you", 10)
	check("a new todo is open and listed", t.state == "open" and t:is_listed() and t:title() == "wire the bar")
	check("a todo without the template needs details", not t:is_specified() and t:title() == "wire the bar")
	check("an empty edit changes nothing", not t:edit("", 11) and t:title() == "wire the bar")
	check("an edit following the template replaces it", t:edit("# wire the health tab\n\nshow agentd health in the bar\n\n## Acceptance criteria\n- Given the bridge died, when the bar redraws, then it shows bridge down", 11) and t:title() == "wire the health tab" and t:is_specified())
	check("sending records the agent", t:send("agent-1", 12) and t.state == "sent" and t.assignee == "agent-1" and t:tone() == "busy")
	local card = expeditio_view_mapper.to_mandatum_card(expeditio_dto_mapper.to_mandatum_dto(t), function(id)
		return id == "agent-1" and "vpn" or "?"
	end, 72)
	check("the card says its status, title and who has it", card[1] == "in progress" and card[2] == "wire the health tab" and card[3] == "vpn · 1m", card)
	check("the message says how to close it", t:message():match("mandatum ab12") and t:message():match("todo done ab12"))
	check("finishing hides it", t:finish("done it", 13) and not t:is_listed() and t.note == "done it")
	check("a done todo can't be sent", not t:send("agent-2", 14))
end)

test("only one agent picks up a todo", function()
	local t = Mandatum.make("cd34", "wire the bar", "/p", "you", 10)
	check("an open todo is free and has no assignee", t:is_free(11) and t.assignee == nil)
	check("a todo needs an agent to be assigned", not t:assign(nil, 11) and t.state == "open")
	check("the first send assigns it to its agent", t:assign("agent-1", 11) and t.state == "assigned" and t.assignee == "agent-1" and not t:is_free(12))
	check("a second agent can't take it", not t:assign("agent-2", 12) and t.assignee == "agent-1")
	check("an assigned todo says who it's going to", expeditio_view_mapper.to_mandatum_card(expeditio_dto_mapper.to_mandatum_dto(t), tostring, 12)[1] == "in progress" and expeditio_view_mapper.who(expeditio_dto_mapper.to_mandatum_dto(t), tostring) == "sending to agent-1")
	check("only its assignee can release it", not t:release("agent-2", 13) and t:release("agent-1", 13) and t.assignee == nil and t:is_free(13))
	check("another agent can then take it", t:assign("agent-2", 14))
	check("another agent can't deliver it", not t:send("agent-1", 15) and t.state == "assigned")
	check("a session that comes back under another id keeps it", t:send("short", 15, "agent-2") and t.state == "sent" and t.assignee == "short")
	check("a sent todo can't be taken or sent again", not t:assign("agent-3", 16) and not t:send("agent-3", 16) and t.assignee == "short")
	local stuck = Mandatum.make("ef56", "fix the bar", "/p", "you", 10)
	stuck:assign("gone", 20)
	check("an assignment left behind by a crash expires", not stuck:is_free(20 + Mandatum.assign_timeout - 1) and stuck:assign("agent-1", 20 + Mandatum.assign_timeout))
	check("mandata stored with an agent or an epic read them as assignee and expeditio", Mandatum:new({ id = "old", state = "sent", agent = "agent-9", epic = "e1" }).assignee == "agent-9" and Mandatum:new({ id = "old", agent = "agent-9", epic = "e1" }):to_table().agent == nil and Mandatum:new({ id = "old", epic = "e1" }).expeditio == "e1")
	check("new session ids are uuids", Miles.new_id(math.random):match("^%x+%-%x+%-4%x+%-[89ab]%x+%-%x+$") ~= nil and #Miles.new_id(math.random) == 36)
end)

test("the todo command adds, lists and finishes", function()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root .. "/repo", "p")
	local env = { XDG_STATE_HOME = root, [Provider.session_env] = "s1" }
	local main = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0]))) .. "/cli/main.lua"
	local function todo(...)
		return vim.system({ "nvim", "--clean", "-l", main, "todo", "-C", root .. "/repo", ... }, { env = env, text = true }):wait()
	end
	local spec = { "--description", "resumed sessions come back idle", "--criteria", "Given agentd restarted, when it boots, then saved sessions resume" }
	local rejected = todo("add", "too short")
	check("add refuses a todo without the template", rejected.code ~= 0 and rejected.stderr:match("description"), rejected.stderr)
	local added = todo("add", "check the resume", unpack(spec))
	local id = vim.trim(added.stdout or "")
	check("add prints the id", added.code == 0 and #id == 4, added)
	local listed = todo("list")
	check("list shows it", listed.stdout:match(id .. "\topen\tcheck the resume") ~= nil, listed)
	local store = make_store(root)
	local t = store:get(Mandatum, id)
	check("an agent's todo is from its session", t and t.from == "s1")
	local epic = t and store:get(Expeditio, t.expeditio)
	check("an unknown session's todo lands in loose ends", epic and epic.title == "loose ends", epic)
	store:update(Miles, "s1", function(a)
		a.title = "vpn work"
	end)
	local named = todo("add", "second thing", unpack(spec))
	local second = store:get(Mandatum, vim.trim(named.stdout or ""))
	check("an agent's todo lands in an expeditio named after its session", second and store:get(Expeditio, second.expeditio).title == "vpn work")
	local chosen = todo("add", "third thing", "--epic", "release", unpack(spec))
	local third = store:get(Mandatum, vim.trim(chosen.stdout or ""))
	check("--epic still picks the expeditio", third and store:get(Expeditio, third.expeditio).title == "release")
	local amended = todo("amend", vim.trim(chosen.stdout), "--criteria", "Given a release, when it ships, then the notes list it")
	check("amend replaces the criteria", amended.code == 0 and todo("show", vim.trim(chosen.stdout)).stdout:match("then the notes list it"), amended.stderr)
	check("amend refuses criteria that aren't Given/when/then", todo("amend", vim.trim(chosen.stdout), "--criteria", "it ships").code ~= 0)
	store:update(Miles, "s2", function(a)
		a.name, a.state = "config-5c", "idle"
	end)
	local handed_id = vim.trim(named.stdout)
	store:update(Mandatum, handed_id, function(t)
		t:send("s1", 1)
	end)
	check("hand refuses a session that isn't running", todo("hand", handed_id, "nobody").code ~= 0)
	local handed = todo("hand", handed_id, "config-5c")
	check("hand moves a todo you were given to the named session", handed.code == 0 and store:get(Mandatum, handed_id).assignee == "s2", handed.stderr)
	check("hand refuses a todo that isn't yours any more", todo("hand", handed_id, "config-5c").code ~= 0)
	todo("done", vim.trim(named.stdout))
	todo("done", vim.trim(chosen.stdout))
	check("done closes it", todo("done", id, "resumed fine").code == 0 and todo("list").stdout == "")
	check("done on an unknown id fails", todo("done", "zzzz").code ~= 0)
	vim.fn.delete(root, "rf")
end)

test("a contubernium splits a todo into stacked branches", function()
	check("a contubernium has two to ten agents", Contubernium.fits(2) and Contubernium.fits(10) and not Contubernium.fits(1) and not Contubernium.fits(11) and not Contubernium.fits(2.5) and not Contubernium.fits(nil))
	local todo = Mandatum.make("ab12", { title = "Split the collector", description = "Gateway and installer.", criteria = { "Given two orgs, when one is revoked, then only it fails" } }, "/p", "you", 1)
	local contubernium = Contubernium.make("t1", "ab12", "/p", "feature/node-24", { "id-a", "id-b", "id-c" }, 2, "otter")
	check("a contubernium is called by its name", contubernium:label() == "contubernium otter" and Contubernium.of({ contubernium }, "id-b") == contubernium and Contubernium.of({ contubernium }, "id-x") == nil)
	local taken = {}
	for _, n in ipairs(Contubernium.contubernium_names) do
		if n ~= "regulus" then
			table.insert(taken, Contubernium:new({ id = n, name = n }))
		end
	end
	check("a new contubernium gets a name no other contubernium has", Contubernium.pick_name(taken, math.random) == "regulus")
	local contubernia = { miles_dto_mapper.to_contubernium_dto(contubernium, function() end) }
	local session = active_rows({ Miles:new({ id = "id-b", state = "working", root = "/p", cwd = "/p" }) }, "/p", 3, nil, contubernia)[1]
	local loner = miles_row(Miles:new({ id = "id-b", state = "working", root = "/p", cwd = "/p" }), 3)
	local stray = miles_row(Miles:new({ id = "id-x", state = "working", root = "/p", cwd = "/p", title = "zebra" }), 3)
	check("members' titles share one format", Contubernium.member_title("birch", "933 birch: integration logging") == "birch · 933 integration logging"
		and Contubernium.member_title("cedar", "Guideline (#933 part 2) · cedar") == "cedar · Guideline (#933 part 2)"
		and Contubernium.member_title("elm", "elm: #933 logging") == "elm · #933 logging"
		and Contubernium.member_title("ash", nil, "Split the collector") == "ash · Split the collector"
		and Contubernium.member_title("pine", "Fix: the pinecone thing") == "pine · Fix: the pinecone thing"
		and Contubernium.member_title("fir", Contubernium.member_title("fir", "fir: logging")) == "fir · logging")
	check("a contubernium shows as one card, led by its first running member", session.name == "contubernium otter" and session.sort_name == "contubernium otter 1" and #active_rows({ Miles:new({ id = "id-a", state = "idle", root = "/p" }), Miles:new({ id = "id-b", state = "working", root = "/p" }) }, "/p", 3, nil, contubernia) == 1 and stray.sort_name == stray.name)
	check("the contubernium card names it and counts its members by state", card_lines(session)[1] == "◆ contubernium otter" and card_lines(session)[3] == "1 working" and not card_lines(loner)[2]:find("contubernium", 1, true), card_lines(session))
	check("members get names in stack order and the first leads", contubernium:decanus().name == "ash" and contubernium.members[2].name == "birch" and contubernium.members[3].name == "cedar")
	local decanus, middle = contubernium:brief(todo, "ash"), contubernium:brief(todo, "birch")
	check("every brief carries the todo", decanus:find("# Split the collector", 1, true) and middle:find("# Split the collector", 1, true))
	check("the brief names everyone in stack order", middle:find("1. ash (lead)\n2. birch\n3. cedar", 1, true) ~= nil, middle)
	check("the bottom of the stack branches off the base branch", decanus:find("Branch off `feature/node-24`", 1, true) ~= nil, decanus)
	check("the others branch off the one below them", middle:find("Branch off ash's branch", 1, true) and contubernium:brief(todo, "cedar"):find("Branch off birch's branch", 1, true))
	check("everyone works in a worktree and rebases", middle:find("own git worktree", 1, true) and middle:find("rebase onto it", 1, true))
	check("the lead proposes the split and closes the todo", decanus:find("You propose the split", 1, true) and decanus:find("done ab12", 1, true))
	check("the others wait for the split and don't close the todo", middle:find("ash proposes the split first", 1, true) and not middle:find("done ab12", 1, true))
	check("the brief says how to talk to the contubernium", middle:find("contubernium send <name|all>", 1, true) and middle:find("contubernium list", 1, true))
	check("a message goes to one member or all but never back", #contubernium:recipients("id-a", "birch") == 1 and #contubernium:recipients("id-a", "all") == 2 and #contubernium:recipients("id-a", "nobody") == 0)
	check("a letter starts with who it's from and what they say", contubernium:letter("id-b", "I'll take the installer"):match("^[^\n]+") == "birch: I'll take the installer" and contubernium:letter("id-b", "x"):find("contubernium send birch", 1, true))
	check("a sender's own name isn't said twice", contubernium:letter("id-b", "birch: no objections"):match("^[^\n]+") == "birch: no objections" and contubernium:letter("id-b", "birch, starting now"):match("^[^\n]+") == "birch: starting now")
	check("a member that started under another id is found by it", contubernium:started("cedar", "short") and contubernium:member_for("short").name == "cedar" and contubernium:has("short"))
	check("a member that didn't start leaves the contubernium", contubernium:leave("id-b") and #contubernium.members == 2 and contubernium:below("cedar").name == "ash")
	local gone, decanus = contubernium:leave("id-a")
	check("when the lead leaves, the next one up leads", gone.name == "ash" and decanus.name == "cedar" and contubernium:decanus().name == "cedar")
	local news = contubernium:news(gone, decanus, "todo")
	check("the new lead hears they lead and close the todo", #news == 1 and news[1].miles == "short" and news[1].text:find("you lead the contubernium now", 1, true) and news[1].text:find("todo done ab12", 1, true), news)
	check("the last one leaving empties the contubernium", select(2, contubernium:leave("short")) == nil and contubernium:is_empty())
end)

test("the contubernium command lists members and passes messages", function()
	local root = vim.fn.tempname()
	vim.fn.mkdir(root, "p")
	local main = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0]))) .. "/cli/main.lua"
	local function contubernium(session, ...)
		return vim.system({ "nvim", "--clean", "-l", main, "contubernium", ... }, { env = { XDG_STATE_HOME = root, [Provider.session_env] = session }, text = true }):wait()
	end
	local store = make_store(root)
	local contubernia = ContuberniumRepository.new(store)
	contubernia:save(Contubernium.make("t1", "ab12", "/p", "main", { "id-a", "id-b" }, 1))
	for _, id in ipairs({ "id-a", "id-b" }) do
		store:update(Miles, id, function(a)
			a.state, a.branch = "working", id == "id-a" and "split/ash" or "split/birch"
		end)
	end
	check("a session outside a contubernium is told so", contubernium("id-x", "list").code ~= 0)
	local listed = contubernium("id-b", "list")
	check("list shows each member's state and branch", listed.code == 0 and listed.stdout:find("ash\tworking\tsplit/ash", 1, true) and listed.stdout:find("birch (you)", 1, true), listed)
	local sent = contubernium("id-a", "send", "birch", "take the installer")
	check("send says who got it", sent.code == 0 and sent.stdout:find("sent to birch", 1, true), sent)
	local held = store:get(Miles, "id-b"):held()
	check("the message waits in the member's outbox", #held == 1 and held[1].text:find("^ash: take the installer") and held[1].text:find("take the installer", 1, true), held)
	check("the sender doesn't get their own message", #store:get(Miles, "id-a"):held() == 0)
	check("an unknown member fails", contubernium("id-a", "send", "nobody", "hi").code ~= 0)
	vim.system({ "nvim", "--clean", "-l", main, "title", "933 birch: integration logging" }, { env = { XDG_STATE_HOME = root, [Provider.session_env] = "id-b" } }):wait()
	check("a member's own title keeps the contubernium format", store:get(Miles, "id-b").title == "birch · 933 integration logging", store:get(Miles, "id-b").title)
	store:update(Miles, "id-c", function(a)
		a.state = "idle"
	end)
	contubernia:update("t1", function(m)
		table.insert(m.members, { name = "cedar", miles = "id-c" })
	end)
	local mandata = composition_root.build(store).mandatum_process
	local todo_id = mandata:add_mandatum(require("workspace.workflow.application.commands.add_mandatum_command").new({ root = "/p", expeditio_title = "split", title = "Split it", description = "Two layers.", criteria = { "Given two layers, when both land, then they stack" }, from = "you" }))
	contubernia:update("t1", function(m)
		m.todo = todo_id
	end)
	mandata:send(require("workspace.workflow.application.commands.send_mandatum_command").new({ mandatum_id = todo_id, miles_id = "id-a" }))
	store:remove(Miles, "id-a")
	local membership = composition_root.build(store).contubernium_membership
	membership:remove_miles("id-a")
	local after = contubernia:get("t1")
	check("a removed lead's contubernium elects the next one up", after and after:decanus().name == "birch" and #after.members == 2, after and after.members)
	check("the todo moves to the new lead", mandata:mandatum(todo_id).assignee == "id-b")
	local told = store:get(Miles, "id-b"):held()
	check("the new lead is told they lead", told[#told].text:find("you lead the contubernium now", 1, true) ~= nil, told)
	check("the rest hear who leads now", store:get(Miles, "id-c"):held()[1].text:find("birch leads the contubernium now", 1, true) ~= nil)
	membership:remove_miles("id-c")
	check("a member leaving doesn't change the lead", contubernia:get("t1"):decanus().name == "birch" and mandata:mandatum(todo_id).assignee == "id-b")
	membership:remove_miles("id-b")
	check("the last member leaving removes the contubernium", contubernia:get("t1") == nil)
	vim.fn.delete(root, "rf")
end)

test("only idle headless cli sessions move to the sdk", function()
	local function session(fields, runtime)
		return miles_row(Miles:new(fields):hydrate({ runtime = runtime }), 10)
	end
	check("an idle headless cli session can move", session({ id = "a", state = "done", root = "/p" }).cannot_move == nil)
	check("a pane session stays", session({ id = "b", state = "idle", root = "/p", pane = 4 }).cannot_move ~= nil)
	check("a busy session waits", session({ id = "c", state = "working", root = "/p" }).cannot_move ~= nil)
	local sdk = MilesProcess.for_miles("d")
	sdk:observe({ event = "verify" }, 1)
	check("an sdk session is already there", session({ id = "d", state = "idle", root = "/p" }, sdk).cannot_move ~= nil)
end)

test("a prompt counts as received by its text, not its clock", function()
	local t = Transcript.new("x", {})
	t.turns = { { prompt = "I dont like it as a new tab", at = 1000, reply = {} } }
	local a = Miles:new({ id = "x", state = "idle" })
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
	local hosted = Miles:new({ id = "h", state = "idle", host = "agentd", root = "/p/.config" })
	local reg = MilesSessionList.new({ { sessionId = "h", pid = 1, status = "idle", name = "config-82" } }, function()
		return true
	end)
	check("a daemon agent picks up its session name", reg:needs_reconcile(hosted) and reg:reconcile(hosted, 10) and hosted:display_name() == "config-82" and hosted.state == "idle")
	check("and then leaves it alone", not reg:needs_reconcile(hosted))
end)

test("a turn set has one card per prompt and at most one active turn", function()
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
	local working = Miles:new({ id = "a", state = "working", updated = 100 })
	local t1 = transcript({ { prompt = "older", at = 10, reply = {} }, { prompt = "I saw duplicates", at = 50, reply = {} } }, { { text = "I saw duplicates", prompt = "I saw duplicates", at = 49 } })
	local set = collect(t1, working, 60)
	sane(set, "leftover queue entry")
	check("a leftover queue entry for the same prompt is dropped", #set.entries == 2 and set.entries[2].state == "working", set.entries)

	local started = Miles:new({ id = "a", state = "idle" })
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

	local busy = Miles:new({ id = "a", state = "working", updated = 100 })
	busy:start_sending("after this", 80)
	set = collect(transcript({ { prompt = "current", at = 75, reply = {} } }), busy, 81)
	sane(set, "sent while busy")
	check("a message sent while busy waits behind the active turn", set.entries[1].state == "working" and set.entries[2].state == "pending")

	busy:hold("held one", 82)
	set = collect(transcript({ { prompt = "current", at = 75, reply = {} } }), busy, 83)
	sane(set, "held")
	check("held messages are pending too", set.entries[2].state == "pending" and set.entries[2].source == "held")

	local idle = Miles:new({ id = "a", state = "done" })
	set = collect(t1, idle, 90)
	sane(set, "idle")
	check("an idle agent has nothing active or pending", #Turn.active_in(set.entries) == 0 and #vim.tbl_filter(function(t)
		return t:is_pending()
	end, set.entries) == 0)
end)

test("the conversation shows an entry until something else takes over", function()
	local v = ConversationScreen:new({ id = "w" })
	check("a todo shows from the answer", v:show_entry("todo", "t1") and v.state == "entry" and v:shows_entry("todo", "t1"))
	check("showing the same entry again changes nothing", not v:show_entry("todo", "t1"))
	check("an epic replaces it", v:show_entry("epic", "e1") and v:shows_entry("epic", "e1"))
	check("the view focuses the entry it shows", v:focus() == "e1")
	check("selecting an agent leaves the entry", v:select("a") and v.state == "answer" and v:focus() == "a")
	v:show_ask("q", "a")
	check("a pending ask isn't replaced by an entry", not v:show_entry("todo", "t3") and v.state == "ask")
	local d = ConversationScreen:new({ id = "w2" })
	d:compose({ agent = "a" })
	check("an entry can be looked at while drafting", d:show_entry("todo", "t1") and d.state == "entry")
end)

test("expeditiones group mandata and track their completion", function()
	local epic = Expeditio.make("e1", "agentd hardening", "/p", "you", 10)
	local function todo(id, state, at, agent)
		local t = Mandatum.make(id, "task " .. id, "/p", "you", at, "e1")
		if state == "sent" or state == "done" then
			t:send(agent or "a1", at + 1)
		end
		if state == "done" then
			t:finish("did it", at + 2)
		end
		if state == "dropped" then
			t:drop(at + 1)
		end
		return t
	end
	local all = { todo("t3", "open", 30), todo("t1", "done", 10), todo("t2", "sent", 20), todo("tx", "dropped", 5), Mandatum.make("other", "x", "/p", "you", 1, "e2") }
	epic:hydrate(all)
	local mine = epic:mandata()
	check("an epic holds its own todos, to do first and done last, without dropped ones", #mine == 3 and mine[1].id == "t3" and mine[2].id == "t2" and mine[3].id == "t1", vim.tbl_map(function(t)
		return t.id
	end, mine))
	local p = epic:progress()
	check("progress counts each status", p.total == 3 and p.done == 1 and p["in progress"] == 1 and p.open == 1, p)
	check("one picked up means in progress", epic:status() == "in progress" and epic:tone() == "busy")
	check("the epic knows what's waiting", vim.deep_equal(epic:waiting(), { "t3" }))
	local names = function(id)
		return id == "a1" and "vpn" or "?"
	end
	local dto = expeditio_dto_mapper.to_expeditio_dto(epic)
	local card = expeditio_view_mapper.to_expeditio_card(dto, names, 70)
	check("the card meters completion", card[1] == "agentd hardening" and card[3] == "in progress · 1 of 3 done" and card[4].percent == "33%" and card[4].label == "1 in progress · 1 open", card)
	local thread = expeditio_view_mapper.to_thread(dto, names, 70)
	check("the thread lists the todos with their status", #thread.items == 3 and thread.items[1].card[1] == "open" and thread.items[2].card[1] == "in progress" and thread.items[2].card[3]:match("^vpn") and thread.items[3].card[1] == "done", thread.items)
	check("entering the thread lands on the first todo", thread:latest_turn().id == "t3")
	local doc = expeditio_view_mapper.to_expeditio_document(dto, names, 70)
	check("the epic document is a checklist", doc.lines[3]:match("^%- %[ %] task t3") and doc.lines[4]:match("^%- %[~%] task t2") and doc.lines[5]:match("^%- %[x%] task t1"), doc.lines)
	check("a fresh expeditio is open", Expeditio.make("e9", "new", "/p", "you", 1):hydrate({}):status() == "open")
	local done_epic = Expeditio.make("e3", "finished", "/p", "you", 5)
	local finished = { Mandatum.make("d1", "x", "/p", "you", 1, "e3") }
	finished[1]:send("a1", 2)
	finished[1]:finish("", 3)
	done_epic:hydrate(finished)
	local listed = Expeditio.listed_in({ epic, done_epic, Expeditio.make("e4", "elsewhere", "/q", "you", 1):hydrate({}) }, "/p")
	check("finished epics and other folders drop off the board", #listed == 1 and listed[1].id == "e1", vim.tbl_map(function(e)
		return e.id
	end, listed))
	check("epics are found by title per repo", Expeditio.find({ epic }, "/p", "agentd hardening") == epic and Expeditio.find({ epic }, "/q", "agentd hardening") == nil)
	check("expeditio drafts are saved, not delivered", Draft.new({ expeditio = true, cwd = "/p" }, "x"):delivery(nil) == "expeditio" and not Draft.starts_session({ expeditio = true, cwd = "/p" }))
	check("a new mandatum's draft is per expeditio", Draft.key({ mandatum = true, in_expeditio = "e1", cwd = "/p" }) == "mandatum-e1" and Draft.key({ expeditio = "e1" }) == "expeditio-e1")
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
	check("pushes are guarded", Review.guards(event("before_tool", { tool_name = "Bash", tool_input = { command = "git push" } })))
	local ctx = { branch = "main", protected = protected, tree = function()
		error("the tree isn't needed for a push")
	end }
	local denied = Review.for_root("/repo"):guard(event("before_tool", { tool_name = "Bash", tool_input = { command = "git push" } }), ctx, "review")
	check("the guard denies a push to main without computing the tree", denied and denied.hookSpecificOutput.permissionDecisionReason:match("main"))
end)

test("a mandatum draft saves a mandatum instead of starting a session", function()
	local new = { mandatum = true, cwd = "/p" }
	local existing = { mandatum = "ab12", cwd = "/p" }
	check("a new mandatum has its own draft per folder", Draft.key(new) == "mandatum--p" and Draft.key(existing) == "mandatum-ab12")
	check("a mandatum draft is saved, not delivered", Draft.new(new, "x"):delivery(nil) == "mandatum")
	check("a mandatum draft isn't a new session", not Draft.starts_session(new) and Draft.starts_session({ cwd = "/p" }))
	check("no drafting card for a mandatum", #active_rows({}, "/p", 10, new) == 0 and #active_rows({}, "/p", 10, { cwd = "/p" }) == 1)
end)

test("agents come with what they own", function()
	local root = vim.fn.tempname()
	local store = make_store(root)
	local agents = MilesRepository.new(store)
	local events = composition_root.build(store).miles_session_events
	store:update(Miles, "a", function(a)
		a.state, a.root = "working", "/p"
	end)
	store:update(Miles, "b", function(b)
		b.state, b.root = "idle", "/p"
	end)
	events:record_report(ProcessReportCommand.new({ type = "runtime", id = "a", provider = Provider.name, event = "verify", model = Provider.name .. "-opus-5-5" }))
	events:record_report(ProcessReportCommand.new({ type = "runtime", id = "a", event = "context", used = 50, window = 100 }))
	events:record_report(ProcessReportCommand.new({ type = "usage", provider = Provider.name, windows = { { name = "5h", used = 0.2 } }, extra = true }))
	store:update(Question, "q1", function(q)
		local fresh = Question.from_sdk({ session = "a", tool = "Bash", input = {} }, "q1", 4)
		for _, f in ipairs(Question.fields) do
			q[f] = fresh[f]
		end
	end)
	local a = agents:get("a")
	check("an agent knows its runtime", a:on_sdk() and a:channel() == "sdk" and a:model_label() == "opus" and a:context_fraction() == 0.5)
	check("and its provider's usage", a:plan_label() == "5h 20%" and a:uses_extra())
	check("and its pending asks", #a:pending_asks() == 1 and a:pending_asks()[1].id == "q1")
	local b
	for _, x in ipairs(agents:all()) do
		b = x.id == "b" and x or b
	end
	check("an agent without a runtime is on the cli", b and not b:on_sdk() and b:channel() == "attach" and #b:pending_asks() == 0 and b:plan_label() == "5h 20%")
	events:mark_processes_lost({ a = true }, 5)
	check("a live runtime is kept", agents:get("a"):on_sdk())
	events:mark_processes_lost({}, 6)
	check("a lost one falls back", not agents:get("a"):on_sdk())
	check("what an agent owns isn't written into it", store:read(Miles, "a").runtime == nil and store:read(Miles, "a").asks == nil)
	vim.fn.delete(root, "rf")
end)

test("the neovim side of agentd holds, reconnects, launches and reports health", function()
	local config = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0])))))
	local res = vim.system({ "nvim", "--headless", "-u", "NONE", "-l", config .. "/nvim/tests/agentd.lua" }, { text = true }):wait()
	check("its own checks pass", res.code == 0 and (res.stdout or ""):match("checks passed") ~= nil, (res.stdout or "") .. (res.stderr or ""))
end)

test("a saved state the machine no longer knows starts over", function()
	local v = ConversationScreen:new({ id = "w", state = "todo", todo = "ab12" })
	check("an old view state falls back to the start", v.state == "answer" and v:show_entry("todo", "ab12"))
	local c = Review.Comment:new({ id = "c", state = "deleted" })
	check("a terminal state stays", c.state == "deleted")
	local a = Question:new({ id = "a", state = "answered" })
	check("an answered ask stays answered", a.state == "answered")
	check("every agent state is known", Miles:new({ id = "x", state = "stopped" }).state == "stopped")
end)

test("todos follow a fixed template", function()
	local text = "# Rotate the agentd log\n\nKeep the log small.\n\n## Acceptance criteria\n- Given the log is over 1MB, when agentd launches, then it moves to agentd.log.1\n- Given a small log, when agentd launches, then it stays"
	local spec = Mandatum.parse(text)
	check("the template parses into its parts", spec.title == "Rotate the agentd log" and spec.description == "Keep the log small." and #spec.criteria == 2, spec)
	check("it validates", Mandatum.validate(spec))
	check("and renders back the same", Mandatum.render(spec) == text, Mandatum.render(spec))
	check("the empty template doesn't validate", not Mandatum.validate(Mandatum.parse(Mandatum.template)))
	local _, why = Mandatum.validate({ title = "x", description = "y", criteria = { "it should work" } })
	check("criteria must be Given, when, then", why and why:match("Given"), why)
	check("a scenario needs words in each part", Mandatum.is_scenario("Given a, when b, then c") and Mandatum.is_scenario("given the bar when it redraws then it shows it") and not Mandatum.is_scenario("Given , when , then "))
	_, why = Mandatum.validate({ title = "x", description = string.rep("long ", 80), criteria = { "Given a, when b, then c" } })
	check("the description stays short", why and why:match("under"), why)
	local t = Mandatum.make("t1", "short and unreadable", "/p", "agent", 1, "e1")
	check("an old one-liner needs details", not t:is_specified() and expeditio_view_mapper.to_mandatum_card(expeditio_dto_mapper.to_mandatum_dto(t), function()
		return "x"
	end, 2)[3]:match("needs details"))
	local ok, err = t:amend({ description = "Explain it." }, 3)
	check("an amend that still misses criteria is refused", not ok and err:match("criterion"), err)
	ok = t:amend({ description = "Explain it.", criteria = { "Given a, when b, then c" } }, 4)
	check("an amend that completes it is kept", ok and t:is_specified() and t:title() == "short and unreadable" and t.text:match("## Acceptance criteria"))
	t:send("a", 5)
	t:finish("", 6)
	check("a done todo can't be amended", not t:amend({ title = "new" }, 7))
end)

test("mandata change only through their expeditio", function()
	local C = function(name)
		return require("workspace.workflow.application.commands." .. name)
	end
	local root = vim.fn.tempname()
	local store = make_store(root)
	local mandata = composition_root.build(store, { clock = os.time }).mandatum_process
	local spec = { title = "Rotate the log", description = "Keep it small.", criteria = { "Given a big log, when agentd launches, then it rotates" } }
	local function add(at)
		return mandata:add_mandatum(C("add_mandatum_command").new({ root = "/p", expeditio_title = "agentd", title = spec.title, description = spec.description, criteria = spec.criteria, from = "you" }))
	end
	local epic = mandata:add_expeditio(C("add_expeditio_command").new({ root = "/p", title = "agentd", from = "you" }))
	check("finding the same expeditio twice gives one", mandata:add_expeditio(C("add_expeditio_command").new({ root = "/p", title = "agentd" })) == epic and #store:all(Expeditio) == 1)
	local id = add()
	check("a mandatum added to it belongs to it", mandata:expeditio(epic).mandata[1].id == id and mandata:expeditio_of(id).id == epic)
	check("assigning goes through the expeditio and only once", mandata:assign(C("assign_mandatum_command").new({ mandatum_id = id, miles_id = "agent-a" })) and not mandata:assign(C("assign_mandatum_command").new({ mandatum_id = id, miles_id = "agent-b" })) and mandata:mandatum(id).assignee == "agent-a")
	check("sending goes through the expeditio", mandata:send(C("send_mandatum_command").new({ mandatum_id = id, miles_id = "agent-a" })) and mandata:mandatum(id).state == "sent")
	local ok, why = mandata:amend(C("amend_mandatum_command").new({ mandatum_id = id, criteria = { "nope" } }))
	check("an amend the expeditio refuses isn't written", not ok and why:match("Given") and #mandata:mandatum(id).criteria == 1, why)
	check("finishing goes through the expeditio", mandata:finish(C("finish_mandatum_command").new({ mandatum_id = id, note = "done" })) and mandata:expeditio(epic).finished)
	check("a finished expeditio leaves the board", #mandata:expeditiones_in("/p") == 0)
	local other = add()
	check("an open mandatum brings it back", #mandata:expeditiones_in("/p") == 1 and #mandata:open_mandata("/p") == 1 and mandata:open_mandata("/p")[1].id == other)
	check("its orders say how to close it", mandata:orders({ other }):find("todo done " .. other, 1, true) ~= nil)
	mandata:drop_expeditio(epic)
	check("removing an expeditio drops its mandata", store:get(Expeditio, epic) == nil and store:get(Mandatum, other).state == "dropped")
	check("an unknown mandatum says so", select(2, mandata:finish(C("finish_mandatum_command").new({ mandatum_id = "zzzz", note = "" }))) == "no mandatum zzzz")
	vim.fn.delete(root, "rf")
end)

test("epics and todos move to expeditiones and mandata once", function()
	local root = vim.fn.tempname()
	local store = make_store(root)
	store:update_record("epics", "e1", function()
		return { id = "e1", title = "old", root = "/p", created = 1 }
	end)
	store:update_record("todos", "t1", function()
		return { id = "t1", state = "sent", epic = "e1", agent = "a1", text = "# old\n\nd\n\n## Acceptance criteria\n- Given a, when b, then c", headline = "old", description = "d", criteria = { "Given a, when b, then c" }, root = "/p", created = 1 }
	end)
	local migration = require("workspace.workflow.infrastructure.outbound.filesystem.expeditio_migration")
	local moved = migration.run(store)
	check("each record is copied", moved.expeditiones == 1 and moved.mandata == 1, moved)
	local mandata = composition_root.build(store, { clock = os.time }).mandatum_process
	local e = mandata:expeditio("e1")
	check("the expeditio keeps its mandata, assignee and all", e and e.title == "old" and e.mandata[1].id == "t1" and e.mandata[1].assignee == "a1" and e.mandata[1].state == "sent", e)
	check("the old folders stay as they were", store:get_record("todos", "t1").epic == "e1")
	check("running it again copies nothing", migration.run(store).mandata == 0)
	vim.fn.delete(root, "rf")
end)

test("mandata made in a worktree belong to the repository", function()
	local base = vim.fn.tempname()
	local main = base .. "/repo"
	vim.fn.mkdir(main, "p")
	local function git(...)
		return vim.system({ "git", "-C", main, ... }, { text = true }):wait()
	end
	git("init", "-q")
	git("-c", "user.email=t@t", "-c", "user.name=t", "commit", "-q", "--allow-empty", "-m", "init")
	git("worktree", "add", "-q", main .. "/.worktrees/wt", "-b", "wt")
	main = vim.uv.fs_realpath(main)
	local store = make_store(base .. "/state")
	local mandata = composition_root.build(store, { clock = os.time }).mandatum_process
	local AddExpeditio = require("workspace.workflow.application.commands.add_expeditio_command")
	local epic = mandata:add_expeditio(AddExpeditio.new({ root = main .. "/.worktrees/wt", title = "from a worktree", from = "s1" }))
	check("the expeditio is stored under the main checkout", mandata:expeditio(epic).root == main, mandata:expeditio(epic).root)
	local id = mandata:add_mandatum(require("workspace.workflow.application.commands.add_mandatum_command").new({ root = main, expeditio_id = epic, title = "x", description = "y", criteria = { "Given a, when b, then c" }, from = "s1" }))
	check("and so are its mandata", store:get(Mandatum, id).root == main)
	check("the main checkout finds it again", mandata:add_expeditio(AddExpeditio.new({ root = main, title = "from a worktree", from = "s1" })) == epic)
	check("listing from the worktree shows it", #mandata:open_mandata(main .. "/.worktrees/wt") == 1)
	vim.fn.delete(base, "rf")
end)

test("an ended session stays ended", function()
	local a = Miles:new({ id = "x", state = "working", host = "agentd" })
	a:hold("queued for later", 1)
	a:apply("end", 2)
	check("ending it right away stops it", a.state == "stopped" and not a:can_release())
	a:apply("stop", 3)
	check("a late Stop doesn't bring it back to done", a.state == "stopped" and not a:can_release())
	check("a hosted agent off the sdk resumes instead of attaching", a:wants_resume())
	local live = Miles:new({ id = "y", state = "idle", host = "agentd" }):hydrate({ runtime = MilesProcess.for_miles("y") })
	live.runtime:observe({ event = "verify" }, 1)
	check("a live sdk agent takes messages directly", not live:wants_resume())
	check("a cli agent takes them over the cli", not Miles:new({ id = "z", state = "idle" }):wants_resume())
	local root = vim.fn.tempname()
	local store = make_store(root)
	store:update(Miles, "c", function(c)
		c.state, c.host, c.root = "idle", "agentd", root
	end)
	composition_root.build(store).miles_session_events:apply(SessionEventCommand.new({ payload = event("prompt", { session_id = "c", cwd = root, prompt = "hi" }), background = true }))
	check("a cli hook clears the daemon mark", store:get(Miles, "c").host == nil and store:get(Miles, "c").state == "working")
	vim.fn.delete(root, "rf")
end)

test("pickers open in the conversation", function()
	local v = ConversationScreen:new({ id = "w" })
	check("nothing to pick", v:take_pick() == nil)
	v:request_pick({ kind = "model", agent = "a" }, 5)
	local p = v:take_pick()
	check("the request is taken once", p and p.kind == "model" and p.agent == "a" and p.at == 5 and v:take_pick() == nil, p)
end)

test("runtimes fall back to the cli", function()
	local r = MilesProcess.for_miles("a")
	check("a runtime starts checking", r.state == "checking" and r:channel() == nil)
	r:observe({ event = "verify", model = "opus" }, 1)
	check("a verified plan runs on the sdk", r.state == "sdk" and r:channel() == "sdk" and r:warning() == nil)
	r:observe({ event = "model", model = Provider.name .. "-haiku-5-5" }, 2)
	check("model changes keep the state", r.state == "sdk" and r:model_label() == "haiku")
	r:observe({ event = "reject", reason = "no subscription" }, 3)
	check("a rejected plan falls back with a warning", r.state == "cli" and r:channel() == nil and r:warning() == "no subscription")
	r:observe({ event = "lose" }, 4)
	check("losing the daemon falls back quietly", r.state == "cli" and r:warning() == nil)
	check("a fallback without a session doesn't leave sdk", not MilesProcess.for_miles("b"):observe({ event = "bogus" }, 1))
	local u = Usage.for_provider(Provider.name)
	check("no usage, no plan label", u:plan_label() == nil)
	u:observe({ windows = { { name = "5h", used = 0.04 }, { name = "week", used = 0.42 } } }, 1)
	check("the plan label shows the tightest window", u:plan_label() == "week 42%")
	local function session(agent, parts)
		return miles_row(Miles:new(agent):hydrate(parts or {}), 10)
	end
	local sdk = MilesProcess.for_miles("x")
	sdk:observe({ event = "verify", model = Provider.name .. "-opus-5-5" }, 1)
	sdk:observe({ event = "context", used = 68000, window = 200000 }, 2)
	local on_sdk = session({ id = "x", state = "working", root = "/p" }, { runtime = sdk, usage = u })
	local m = card_lines(on_sdk)[4]
	check("an sdk card meters its context", m and m.fraction == 0.34 and m.percent == "34%" and m.label == "week 42% · opus", m)
	check("an sdk card isn't flagged", card_lines(on_sdk)[2] == "p")
	local plain = card_lines(session({ id = "x", state = "working", root = "/p" }))
	check("a headless agent off the sdk is flagged cli by its place", plain[2] == "p · cli" and plain[4] == nil, plain)
	local pane = session({ id = "y", state = "working", root = "/p", pane = 3 })
	check("a terminal agent off the sdk doesn't warn", card_lines(pane)[4] == nil)
	local fallen = MilesProcess.for_miles("x")
	fallen:observe({ event = "reject", reason = "api key set" }, 3)
	local rejected = card_lines(session({ id = "x", state = "working", root = "/p" }, { runtime = fallen, usage = u }))
	check("a rejected plan shows as cli without a bar", rejected[2] == "p · cli" and rejected[4].fraction == nil and rejected[4].label == "week 42%", rejected)
	local stopped = miles_view_mapper.to_file_row({ id = "z", path = "/c/z.jsonl", mtime = 1 }, { cwd = "/p" }, 1, 10)
	check("an ended session has no meter", card_lines(stopped)[4] == nil)
	local mr = MergeRequest.for_root("/p", "feat")
	mr:observe({ iid = 7, state = "opened", requested_by = { "bob" } }, 1)
	local with_mr = card_lines(session({ id = "x", state = "working", root = "/p" }, { runtime = sdk, usage = u }), nil, mr, 1)
	local line = with_mr[4]
	check("the mr gets its own line under the status", with_mr[2] == "p" and line.segments and #line.segments == 1 and line.segments[1][1] == "!7 changes requested by bob" and line.segments[1][2] == "bad", with_mr)
	check("the meter moves below it", with_mr[5] and with_mr[5].fraction == 0.34, with_mr[5])
	mr:claim("/p", "feat", 5)
	local fetching = card_lines(session({ id = "x", state = "working", root = "/p" }, { runtime = sdk, usage = u }), nil, mr, 6)[4]
	check("the mr line shows gitlab being fetched", fetching.segments[3] and fetching.segments[3][1] == "fetching comments" and fetching.segments[3][2] == "busy", fetching)
	local none = MergeRequest.for_root("/q", "feat")
	none:claim("/q", "feat", 5)
	local quiet = card_lines(session({ id = "x", state = "working", root = "/q" }), nil, none, 6)
	check("no mr line while a branch without an mr is checked", #quiet == 3, quiet)
	none:observe(nil, 7)
	local stale = card_lines(session({ id = "x", state = "working", root = "/q" }), nil, none, 5 + MergeRequest.interval * 4)
	local ready = MergeRequest.for_root("/r", "feat")
	ready:observe({ iid = 3, state = "opened", pipeline = "running", merge_status = "discussions_not_resolved" }, 1)
	local lines = card_lines(session({ id = "x", state = "working", root = "/r" }), nil, ready, 2)
	check("pipeline and merge state get a line under the mr", lines[5] and lines[5].segments[1][1] == "pipeline running" and lines[5].segments[1][2] == "busy" and lines[5].segments[3][1] == "threads open" and lines[5].segments[3][2] == "bad", lines)
	ready:observe({ iid = 3, state = "opened", pipeline = "success", merge_status = "mergeable" }, 3)
	local green = ready:readiness()
	check("a passing mergeable mr says so", green.segments[1][1] == "pipeline passed" and green.segments[3][1] == "ready to merge" and green.segments[3][2] == "ok", green)
	ready:observe({ iid = 3, state = "opened", merge_status = "checking" }, 4)
	check("no pipeline and an unknown merge state leave no line", ready:readiness() == nil and #card_lines(session({ id = "x", state = "working", root = "/r" }), nil, ready, 5) == 4)
	ready:observe({ iid = 3, state = "opened", requested_by = { "eve" }, merge_status = "requested_changes", pipeline = "failed" }, 6)
	local asked = ready:readiness()
	check("changes requested isn't said twice", ready:label() == "!3 changes requested by eve" and #asked.segments == 1 and asked.segments[1][1] == "pipeline failed", asked)
	ready:observe({ iid = 3, state = "opened", pipeline = "failed", merge_status = "requested_changes" }, 7)
	check("gitlab's own changes requested shows when reviewers didn't say it", ready:readiness().segments[3][1] == "changes requested")
	ready:observe({ iid = 3, state = "merged", pipeline = "success", merge_status = "not_open" }, 8)
	check("a merged mr has no readiness line", ready:readiness() == nil)
	local broken = MergeRequest.for_root("/f", "feat")
	broken:observe({ iid = 5, web_url = "mr5", state = "opened", pipeline = "running", pipeline_id = 10 }, 1)
	check("a running pipeline isn't handed over", not broken:failure_to_report())
	broken:observe({ iid = 5, web_url = "mr5", state = "opened", pipeline = "failed", pipeline_id = 10, pipeline_url = "p10", pipeline_run = "t1" }, 2)
	check("a failed pipeline is handed over once", broken:take_failure() and not broken:take_failure() and not broken:failure_to_report())
	check("the card says the agent has it", broken:readiness().segments[1][1] == "pipeline failed, sent to the agent")
	broken:observe({ iid = 5, web_url = "mr5", state = "opened", pipeline = "failed", pipeline_id = 10, pipeline_url = "p10", pipeline_run = "t1" }, 3)
	check("the next poll of the same run doesn't hand it over again", not broken:failure_to_report())
	check("a failed send can be handed over again", broken:return_failure(broken.reported_run) and broken:take_failure())
	check("a first failure isn't a rerun", not broken:is_rerun() and not broken:failure_prompt({}):find("again", 1, true))
	broken:observe({ iid = 5, web_url = "mr5", state = "approved", approved = true, approved_by = { "duo" }, pipeline = "running", pipeline_id = 10, pipeline_run = "t1" }, 4)
	check("an approved mr is still watched", broken:is_live() and not broken:failure_to_report())
	broken:observe({ iid = 5, web_url = "mr5", state = "opened", approved = true, approved_by = { "duo" }, pipeline = "failed", pipeline_id = 10, pipeline_url = "p10", pipeline_run = "t2" }, 5)
	check("a retried job that fails the same pipeline again is handed over", broken.state == "approved" and broken:take_failure() and broken:is_rerun())
	check("the agent hears it failed after the retry", broken:failure_prompt({}):find("!5 failed again, after it was retried: p10", 1, true) ~= nil, broken:failure_prompt({}))
	broken:observe({ iid = 5, web_url = "mr5", state = "opened", approved = true, approved_by = { "duo" }, pipeline = "failed", pipeline_id = 10, pipeline_url = "p10", pipeline_run = "t3" }, 6)
	check("a third failed run is handed over", broken:take_failure() and broken.report_count == 3)
	broken:observe({ iid = 5, web_url = "mr5", state = "opened", approved = true, approved_by = { "duo" }, pipeline = "failed", pipeline_id = 10, pipeline_url = "p10", pipeline_run = "t4" }, 7)
	check("after three the agent isn't sent it again", not broken:failure_to_report() and broken:gave_up())
	check("and the card says it keeps failing", broken:readiness().segments[1][1] == "pipeline failed 3 times" and broken:readiness().segments[1][2] == "bad", broken:readiness())
	broken:observe({ iid = 5, web_url = "mr5", state = "opened", pipeline = "failed", pipeline_id = 11, pipeline_url = "p11", pipeline_run = "t5" }, 8)
	check("a new pipeline starts the count over", broken:take_failure() and broken.report_count == 1 and not broken:is_rerun())
	local prompt = broken:failure_prompt({
		{ id = 7, name = "test", stage = "test", failure_reason = "script_failure", web_url = "j7" },
		{ id = 8, name = "lint", stage = "check", allow_failure = true, web_url = "j8" },
	})
	check("the prompt names the pipeline and its blocking jobs", prompt:find("!5 failed: p11", 1, true) and prompt:find("- test (stage test, job 7, script failure): j7", 1, true) and not prompt:find("lint", 1, true), prompt)
	broken:observe({ iid = 5, state = "merged", pipeline = "failed", pipeline_id = 12 }, 9)
	check("a merged mr's failed pipeline isn't handed over", not broken:failure_to_report())
	local tangled = MergeRequest.for_root("/c", "feat")
	local function conflicted(head, status, at)
		tangled:observe({ iid = 6, web_url = "mr6", state = "opened", merge_status = status or "conflict", head_sha = head, target_branch = "main" }, at)
	end
	conflicted("a1", "mergeable", 1)
	check("a mergeable mr has no conflicts to hand over", not tangled:conflicts_to_report())
	conflicted("a1", nil, 2)
	check("conflicts are handed over once per head", tangled:take_conflicts() and not tangled:take_conflicts() and not tangled:conflicts_to_report())
	check("the card says the agent has the conflicts", tangled:readiness().segments[1][1] == "conflicts, sent to the agent", tangled:readiness())
	check("the prompt names the target branch and asks for a merge", tangled:conflicts_prompt():find("!6 has merge conflicts with main: mr6", 1, true) and tangled:conflicts_prompt():find("merge `origin/main`", 1, true), tangled:conflicts_prompt())
	check("a failed send can hand the conflicts over again", tangled:return_conflicts("a1") and tangled:take_conflicts())
	conflicted("a1", "checking", 3)
	conflicted("a1", nil, 4)
	check("gitlab rechecking doesn't hand the same conflicts over twice", not tangled:conflicts_to_report())
	conflicted("a2", nil, 5)
	check("a new push that still conflicts is handed over again", tangled:take_conflicts() and tangled.conflict_count == 2 and tangled:conflicts_prompt():find("!6 still has", 1, true))
	conflicted("a3", nil, 6)
	tangled:take_conflicts()
	conflicted("a4", nil, 7)
	check("after three tries the agent isn't sent the conflicts again", not tangled:conflicts_to_report() and tangled:readiness().segments[1][1] == "conflicts after 3 tries" and tangled:readiness().segments[1][2] == "bad", tangled:readiness())
	conflicted("a4", "mergeable", 8)
	conflicted("a4", nil, 9)
	check("conflicts that come back after a clean merge state start over", tangled:take_conflicts() and tangled.conflict_count == 1)
	tangled:observe({ iid = 6, state = "merged", merge_status = "conflict", head_sha = "a5" }, 10)
	check("a merged mr's conflicts aren't handed over", not tangled:conflicts_to_report())
	local review = Review.for_root("/r")
	local remote = review:add({ path = "a.lua", line1 = 1, text = "fix", remote = { thread = "t1", iid = 3, notes = 1 } }, math.random, 1)
	review:add({ path = "b.lua", line1 = 2, text = "local note" }, math.random, 1)
	check("an unresolved remote thread isn't addressed", not review:addresses(3) and not review:addresses(99))
	review:send({ remote }, 2)
	review:resolve(remote.id, "done", 3)
	check("resolving every remote thread addresses the mr", review:addresses(3))
	local asked_mr = MergeRequest.for_root("/r", "feat")
	asked_mr:observe({ iid = 3, state = "opened", requested_by = { "eve" }, merge_status = "requested_changes" }, 9)
	asked_mr:hydrate({ addressed = review:addresses(3) })
	local text, tone = asked_mr:label()
	check("an addressed mr waits on the reviewer instead of asking for changes", text == "!3 changes addressed for eve" and tone == "busy", text)
	asked_mr:observe({ iid = 3, state = "opened", merge_status = "requested_changes" }, 10)
	check("gitlab's changes requested reads as awaiting re-review once addressed", asked_mr:readiness().segments[1][1] == "awaiting re-review" and asked_mr:label() == "!3 open")
	check("a stalled poller gets a line even without an mr", stale[4] and stale[4].segments[1][1]:find("gitlab unchecked", 1, true) ~= nil, stale)
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
	local a = make_store(root):get(Miles, "counter")
	check("200 increments", a and a.pid == 200, a and a.pid)
	vim.fn.delete(root, "rf")
end)

test("transcript keeps prompts from other sessions", function()
	local lines = {
		vim.json.encode({ type = "user", isMeta = true, timestamp = "2026-11-04T10:00:00Z", origin = { kind = "peer", name = "lead", body = "you own #900" }, message = { content = "Another session sent a message" } }),
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

test("merge requests follow gitlab", function()
	local mr = MergeRequest.for_root("/repo", "feat")
	check("no mr yet", mr.state == "none" and mr:label() == nil)
	check("first check claims", mr:claim("/repo", "feat", 100) and mr.checked_at == 100)
	check("not due again", not mr:claim("/repo", "feat", 120))
	check("a new branch is due at once", mr:claim("/repo", "other", 121))
	mr:observe({ iid = 42, web_url = "https://gitlab.com/x/-/merge_requests/42", title = "t", state = "opened" }, 130)
	check("opened", mr.state == "open" and mr:label() == "!42 open" and mr:is_live(), mr:label())
	mr:observe({ iid = 42, web_url = "u", state = "opened", approved = true, approved_by = { "bob" } }, 140)
	check("approved", mr.state == "approved" and mr:label() == "!42 approved by bob", mr:label())
	mr:observe({ iid = 42, web_url = "u", state = "opened", approved = true, approved_by = { "bob" }, requested_by = { "eve" } }, 142)
	check("changes requested beat an approval", mr.state == "changes" and mr:label() == "!42 changes requested by eve" and mr:is_live(), mr:label())
	mr:observe({ iid = 42, web_url = "u", state = "opened", requested_by = {} }, 144)
	check("back to open once nobody requests changes", mr.state == "open" and mr:label() == "!42 open", mr:label())
	for _, state in ipairs({ "open", "changes", "approved" }) do
		check("review state " .. state .. " is shared with gitlab", Review.machine.states[state] and MergeRequest.machine.states[state], state)
	end
	mr:observe({ iid = 42, web_url = "u", state = "merged" }, 150)
	check("merged", mr.state == "merged" and not mr:is_live())
	check("merged can't be approved", not mr:observe({ iid = 42, state = "opened", approved = true }, 160) and mr.state == "merged")
	check("a merged branch isn't polled again", mr:is_finished() and not mr:claim("/repo", "other", 1000))
	check("a merged branch doesn't look like a stalled poller", mr:activity(5000) == nil)
	mr:poke("/repo")
	check("an agent's mr action checks a merged branch once more", mr:claim("/repo", "other", 1001) and not mr:claim("/repo", "other", 2000))
	check("a new branch in the same folder is polled again", mr:claim("/repo", "next", 2001))
	mr:observe(nil, 170)
	check("gone", mr.state == "none" and not mr:exists())

	local polled = MergeRequest.for_root("/repo", "feat")
	polled:claim("/repo", "feat", 200)
	check("a claim shows gitlab being checked", polled:activity(201) == "checking gitlab")
	polled:observe({ iid = 9, state = "opened" }, 202)
	check("nothing to show once it answered, comments come in the same answer", polled:activity(203) == nil)
	polled:claim("/repo", "feat", 200 + MergeRequest.interval)
	local doing, tone = polled:activity(201 + MergeRequest.interval)
	check("checking an open mr says it fetches comments", doing == "fetching comments" and tone == "busy", doing)
	polled:observe({ iid = 9, state = "opened" }, 202 + MergeRequest.interval)
	check("a poller that stopped shows up", polled:activity(polled.checked_at + MergeRequest.interval * 3 + 60) == "gitlab unchecked for 4m", polled:activity(polled.checked_at + MergeRequest.interval * 3 + 60))
	polled:claim("/repo", "feat", 300)
	polled:fail("glab: 401", 301)
	check("a failed check says so", polled:activity(302) == "gitlab failed")
	polled:claim("/repo", "feat", 290 + MergeRequest.fetch_timeout + MergeRequest.interval)
	check("a fetch that never finished stops showing", polled:activity(400 + MergeRequest.fetch_timeout * 2) ~= "fetching comments")
	check("a fresh mr from an agent's tool is checked at once", MergeRequest.pokes(event("after_tool", { tool_name = "mcp__plugin_gitlab_gitlab__accept_merge_request", tool_input = { sha = "a" } })))
	check("the same tool before it runs isn't", not MergeRequest.pokes(event("before_tool", { tool_name = "mcp__plugin_gitlab_gitlab__accept_merge_request", tool_input = { sha = "a" } })))
	check("other tools aren't", not MergeRequest.pokes(event("after_tool", { tool_name = "Bash", tool_input = { command = "ls" } })))
	polled:poke("/elsewhere")
	check("a poke makes it due", polled:due(polled.checked_at or 0) and polled.root == "/repo")

	check("the project path comes from any remote", MergeRequest.project_path("git@gitlab.com:a/b/c.git\n") == "a/b/c" and MergeRequest.project_path("https://gitlab.example.com/a/b.git") == "a/b" and MergeRequest.project_path("ssh://git@gitlab.com:2222/a/b.git") == "a/b" and MergeRequest.project_path("") == nil)
	local watched = MergeRequest.watched({
		{ id = "a", running = true, root = "/w1", branch = "feat" },
		{ id = "b", running = true, root = "/w1", branch = "feat" },
		{ id = "c", running = false, root = "/w2", branch = "done-branch" },
		{ id = "d", running = true, root = "/w3", branch = "other" },
		{ id = "e", running = true, root = "/w4" },
	})
	check("only folders with a running session are polled, once each", #watched == 2 and watched[1].root == "/w1" and watched[2].root == "/w3", watched)
	local finishing = MergeRequest.for_root("/w", "feat")
	finishing:observe({ iid = 21, state = "opened", target_branch = "main" }, 1)
	check("an open mr has nothing to clean up", not finishing:cleanup_to_report())
	local before = finishing.state
	finishing:observe({ iid = 21, state = "merged", target_branch = "main" }, 2)
	check("the poll that sees the merge knows it", finishing:merged_from(before) and not finishing:merged_from("merged"))
	check("the cleanup is handed over once", finishing:take_cleanup() and not finishing:take_cleanup() and finishing.cleaned == 21)
	check("a failed send can try again", finishing:return_cleanup(21) and finishing:take_cleanup())
	local text = finishing:cleanup_prompt()
	check("the agent is told what to clean and to keep unmerged work", text:find("!21 was merged into main, so `feat` is done", 1, true) and text:find("stop and tell me", 1, true)
		and text:find("If `/w` is a worktree, remove it", 1, true) and text:find("delete the local branch `feat`", 1, true) and text:find("switch it to `main`, pull it", 1, true)
		and text:find("not the folder you're working in", 1, true), text)
	check("without mandata in progress the message doesn't mention any", not text:find("mandata you were sent", 1, true))
	local mine = Mandatum.make("aa11", "Close the collector gaps", "/w", "you", 1)
	mine:send("agent-1", 5)
	local older = Mandatum.make("bb22", "Keep the trace across await", "/w", "you", 1)
	older:send("agent-1", 3)
	local theirs = Mandatum.make("cc33", "Someone else's", "/w", "you", 1)
	theirs:send("agent-2", 4)
	local finished = Mandatum.make("dd44", "Already done", "/w", "you", 1)
	finished:send("agent-1", 2)
	finished:finish("did it", 6)
	local open = Mandatum.make("ee55", "Not sent yet", "/w", "you", 1)
	local listed = Mandatum.in_progress_for({ mine, theirs, finished, open, older }, "agent-1")
	check("an agent's todos in progress are the sent ones assigned to it, oldest first", #listed == 2 and listed[1].id == "bb22" and listed[2].id == "aa11", vim.tbl_map(function(t)
		return t.id
	end, listed))
	local with_todos = finishing:cleanup_prompt(expeditio_dto_mapper.to_mandatum_dtos(listed))
	check("the merge message lists them and says how to close the ones it finishes", with_todos:find("- bb22 Keep the trace across await", 1, true) and with_todos:find("- aa11 Close the collector gaps", 1, true)
		and with_todos:find(Mandatum.done_command .. " done <id>", 1, true) and with_todos:find("leave the others open", 1, true), with_todos)
	local main_agent = Miles:new({ id = "m", state = "idle", root = "/repo" })
	local nested = Miles:new({ id = "n", state = "working", root = "/repo/.worktrees/x" })
	check("the session in the folder itself gets it, not one in a worktree under it", Review.recipient({ main_agent, nested }, "/repo") == main_agent)
	check("two sessions in the same folder still need you to pick", Review.recipient({ main_agent, Miles:new({ id = "m2", state = "idle", root = "/repo" }), nested }, "/repo") == nil)
	check("no merge request in the answer is none", MergeRequest.from_graphql(nil) == nil and #MergeRequest.discussions_from_graphql(nil) == 0)
	local node = {
		iid = "12", webUrl = "https://gitlab.com/g/p/-/merge_requests/12", title = "t", state = "opened", detailedMergeStatus = "DISCUSSIONS_NOT_RESOLVED", approved = true,
		approvedBy = { nodes = { { username = "duo" } } },
		reviewers = { nodes = { { username = "eve", mergeRequestInteraction = { reviewState = "REQUESTED_CHANGES" } }, { username = "bob", mergeRequestInteraction = { reviewState = "UNREVIEWED" } } } },
		headPipeline = { id = "gid://gitlab/Ci::Pipeline/77", status = "FAILED", finishedAt = "f1", updatedAt = "u1", path = "/g/p/-/pipelines/77" },
		diffHeadSha = "abc", targetBranch = "main",
		discussions = { nodes = { { id = "gid://gitlab/Discussion/abc123", notes = { nodes = { { system = false, body = "fix", resolvable = true, resolved = false, author = { username = "eve" }, position = { newPath = "a.lua", newLine = 4 } } } } } } },
	}
	local snap = MergeRequest.from_graphql(node)
	check("graphql gives the same snapshot as the rest calls did", snap.iid == 12 and snap.state == "opened" and snap.merge_status == "discussions_not_resolved" and snap.approved and snap.approved_by[1] == "duo"
		and #snap.requested_by == 1 and snap.requested_by[1] == "eve" and snap.pipeline == "failed" and snap.pipeline_id == 77 and snap.pipeline_run == "f1"
		and snap.pipeline_url == "https://gitlab.com/g/p/-/pipelines/77" and snap.head_sha == "abc" and snap.target_branch == "main", snap)
	local from_graphql = MergeRequest.threads(MergeRequest.discussions_from_graphql(node))
	check("graphql discussions keep the rest thread ids", #from_graphql == 1 and from_graphql[1].id == "abc123" and from_graphql[1].path == "a.lua" and from_graphql[1].line == 4 and from_graphql[1].author == "eve" and not from_graphql[1].resolved, from_graphql)
	local threads = MergeRequest.threads({
		{ id = "d1", notes = { { body = "rename this", resolvable = true, resolved = false, author = { username = "bob" }, position = { new_path = "a.lua", new_line = 3 } } } },
		{ id = "d2", notes = { { body = "general", resolvable = true, resolved = false, author = { username = "eve" } }, { body = "+1", resolvable = true, resolved = false, author = { username = "bob" } } } },
		{ id = "d3", notes = { { body = "changed the description", system = true } } },
		{ id = "d4", notes = { { body = "nice", resolvable = false, author = { username = "bob" } } } },
		{ id = "d5", notes = { { body = "done", resolvable = true, resolved = true, author = { username = "bob" }, position = { old_path = "b.lua", old_line = 9 } } } },
	})
	check("only resolvable threads", #threads == 3, threads)
	check("diff thread", threads[1].path == "a.lua" and threads[1].line == 3 and threads[1].text == "@bob: rename this" and not threads[1].resolved, threads[1])
	check("thread notes joined", threads[2].notes == 2 and threads[2].text == "@eve: general\n\n@bob: +1" and threads[2].path == nil, threads[2])
	check("resolved thread on an old line", threads[3].resolved and threads[3].path == "b.lua" and threads[3].line == 9, threads[3])

	local r = Review:new({ id = Review.key("/repo"), root = "/repo" })
	local got = r:import(threads, 42, math.random, 1)
	check("unresolved threads come in", #got.added == 2 and #r.comments == 2, got)
	local file, general = got.added[1], got.added[2]
	check("file comment", file.key == "/repo/a.lua" and file:location() == "a.lua:3" and file.remote.thread == "d1", file:to_table())
	check("general comment", general.key == nil and general:location() == "merge request !42", general:location())
	check("import is idempotent", #r:import(threads, 42, math.random, 2).added == 0 and #r.comments == 2)
	r:send({ file, general }, 3, "agent")
	check("sent comments are open", file:is_open() and r.state == "changes")
	r:resolve(file.id, "renamed it", 4, "agent")
	check("waits to be pushed", #r:unpushed(42) == 1 and #r:unpushed(7) == 0)
	check("pushed", r:mark_pushed(file.id, 2) and #r:unpushed(42) == 0)
	threads[1].notes, threads[1].text = 3, "@bob: rename this\n\n@me: renamed it\n\n@bob: not quite"
	local again = r:import(threads, 42, math.random, 5)
	check("a new reply reopens it", #again.reopened == 1 and file:is_draft() and file.text:match("not quite"), file:to_table())
	threads[2].resolved = true
	local closed = r:import(threads, 42, math.random, 6)
	check("resolved on gitlab closes it", #closed.closed == 1 and general.state == "resolved" and general.remote.pushed, general:to_table())
	r:delete(file.id, 7)
	threads[1].resolved = false
	check("a deleted thread stays away", #r:import(threads, 42, math.random, 8).added == 0)
	local back = Review:new(vim.json.decode(vim.json.encode(r:to_table())))
	check("dismissed survives a roundtrip", back.dismissed and back.dismissed.d1, back.dismissed)
	local fresh = Review:new({ id = Review.key("/repo"), root = "/repo" })
	local added = fresh:import({ { id = "d9", path = "a.lua", line = 2, text = "@bob: why?", notes = 1 } }, 42, math.random, 1).added
	local text = Review.prompt(added, "review -C /repo", function()
		return { "x = 1" }
	end, function(c)
		return c.text
	end)
	check("prompt names the merge request", text:find("[" .. added[1].id .. "] a.lua:2 (GitLab !42)", 1, true) ~= nil, text)
	check("prompt says where the note goes", text:find("posted as a reply", 1, true) ~= nil, text)
	local parsed = Review.parse_prompt(text)
	check("gitlab prompt parses", parsed and parsed[2] and parsed[2].quote[1] == "x = 1" and parsed[2].text == "@bob: why?", parsed)
end)

test("stepping through review comments", function()
	local r = Review:new({ id = Review.key("/repo"), root = "/repo" })
	local b5 = r:add({ key = "/repo/b.lua", path = "b.lua", line1 = 5, text = "x" }, math.random, 1)
	local a9 = r:add({ key = "/repo/a.lua", path = "a.lua", line1 = 9, text = "x" }, math.random, 1)
	local a2 = r:add({ key = "/repo/a.lua", path = "a.lua", line1 = 2, text = "x" }, math.random, 1)
	r:add({ key = "reply", path = "answer", line1 = 1, text = "x" }, math.random, 1)
	r:add({ path = "merge request !4", text = "x" }, math.random, 1)
	local list = r:in_files()
	check("files only, in order", #list == 3 and list[1] == a2 and list[2] == a9 and list[3] == b5, list)
	check("next from nowhere", Review.step(list, nil, nil, 1) == a2)
	check("next in the same file", Review.step(list, "a.lua", 2, 1) == a9)
	check("next runs into the next file", Review.step(list, "a.lua", 9, 1) == b5)
	check("next wraps", Review.step(list, "b.lua", 5, 1) == a2)
	check("previous", Review.step(list, "b.lua", 5, -1) == a9)
	check("previous wraps", Review.step(list, "a.lua", 1, -1) == b5)
	r:send({ a9 }, 2)
	local counts = r:by_path()
	check("counts per file", counts["a.lua"].draft == 1 and counts["a.lua"].sent == 1 and counts["b.lua"].draft == 1 and not counts.answer, counts)
end)

test("a usage limit stops the agent until it continues", function()
	local format = require("workspace.shared.lib.format")
	local a = Miles:new({ id = "lim", state = "working", updated = 100, title = "lim" })
	check("a limit report is the agent's", Miles.observes({ event = "limit" }) and not Miles.observes({ event = "context" }))
	check("a limit stops the work", a:observe({ event = "limit", resets_at = 1000, window = "5h" }, 100) and a.state == "limited")
	local word, tone = a:status()
	check("a limited agent is red", word == "limited" and tone == "limit", { word, tone })
	check("it says when the limit resets", a:progress(400) == "5h resets " .. format.clock(1000, 400) .. " · in 10m", a:progress(400))
	check("it says it continues once reset", a:progress(1100) == "5h reset " .. format.clock(1000, 1100) .. " · continuing", a:progress(1100))
	local s = miles_row(a, 400)
	check("the card is red and shows the reset", s.kind == "limit" and s.word:find("resets", 1, true) ~= nil, s.word)
	a:apply("stop", 101)
	a:apply("start", 102)
	check("a late stop or restart keeps it limited", a.state == "limited" and a.limit.resets_at == 1000)
	check("it outranks working agents", Miles.most_pressing({ Miles:new({ id = "w", state = "working" }), a }) == a)
	check("it can continue", a:can_continue() and miles_row(a, 400).cannot_continue == nil)
	check("continuing goes back to work and forgets the limit", a:continue(200) and a.state == "working" and a.limit == nil)
	check("a working agent can't continue", not a:can_continue() and not a:continue(201))
	local quiet = Miles:new({ id = "q", state = "idle" })
	quiet:observe({ event = "limit" }, 5)
	check("a limit without a reset time just says limited", quiet.state == "limited" and quiet:progress(6) == nil and miles_row(quiet, 6).word == "limited")
	check("a new prompt lifts it too", quiet:apply("prompt", 7) and quiet.state == "working" and quiet.limit == nil)
	local gone = Miles:new({ id = "g", state = "stopped" })
	check("an ended agent isn't limited", not gone:observe({ event = "limit", resets_at = 1 }, 1) and gone.limit == nil)
	check("an ended session can't continue", miles_row(gone, 1).cannot_continue ~= nil)
end)

test("agentd's limit report reaches the agent", function()
	local root = vim.fn.tempname()
	local store = make_store(root)
	local handler = require("workspace.legio.infrastructure.inbound.agentd_bridge").new(store, function() end)
	handler:dispatch({ op = "hook", id = 1, payload = raw("start", { session_id = "s1", cwd = root }) })
	handler:dispatch({ op = "hook", id = 2, payload = raw("prompt", { session_id = "s1", cwd = root }) })
	handler:dispatch({ op = "runtime", report = { type = "runtime", id = "s1", provider = Provider.name, event = "limit", resets_at = 1793881800, window = "5h" } })
	local a = MilesRepository.new(store):get("s1")
	check("the agent is limited with its reset time", a.state == "limited" and a.limit.resets_at == 1793881800 and a.limit.window == "5h", a)
	check("the agent is unread", a:unread())
	store:update(Miles, "s1", function(x)
		return x:mark_read(x.activity)
	end)
	handler:dispatch({ op = "runtime", report = { type = "runtime", id = "s1", provider = Provider.name, event = "limit", resets_at = 1793881800, window = "5h" } })
	check("a repeated limit from a restarted agentd doesn't ping again", not MilesRepository.new(store):get("s1"):unread())
	handler:dispatch({ op = "runtime", report = { type = "runtime", id = "nobody", provider = Provider.name, event = "limit", resets_at = 1 } })
	check("a limit for an unknown session makes no agent", store:get(Miles, "nobody") == nil)
	handler:dispatch({ op = "hook", id = 3, payload = raw("prompt", { session_id = "s1", cwd = root, prompt = "continue" }) })
	check("the next prompt puts it back to work", store:get(Miles, "s1").state == "working" and store:get(Miles, "s1").limit == nil)
	vim.fn.delete(root, "rf")
end)

test("the diff view remembers where you were and which hunks you saw", function()
	local p = DiffProgress.for_root("/repo")
	check("nothing is known about a fresh repo", p:position() == nil and p:badge("a.lua", "s1") == nil)
	check("knowing a file's hunks is a change", p:know("a.lua", { "h1", "h2" }, "s1") and not p:know("a.lua", { "h1", "h2" }, "s1"))
	check("an unseen file has no badge", p:badge("a.lua", "s1") == nil)
	check("seeing a hunk counts once", p:see("a.lua", "h1") and not p:see("a.lua", "h1") and p:has_seen("a.lua", "h1"))
	check("a partly seen file says how far", p:badge("a.lua", "s1")[1] == "1/2" and p:badge("a.lua", "s1")[2] == "partly")
	p:see("a.lua", "h2")
	check("a fully seen file is ticked", p:badge("a.lua", "s1")[1] == "✓")
	check("a file edited since says so", p:badge("a.lua", "s2")[2] == "changed")
	p:know("a.lua", { "h2", "h3" }, "s2")
	check("hunks that changed are unseen again, the rest stay seen", p:has_seen("a.lua", "h2") and not p:has_seen("a.lua", "h3") and p:badge("a.lua", "s2")[1] == "1/2")
	p:know("a.lua", { "h1", "h2" }, "s3")
	check("a hunk that comes back, like in the branch view after the working tree view, is still seen", p:badge("a.lua", "s3")[1] == "✓")
	p:know("a.lua", { "h2", "h3" }, "s2")
	check("the position is remembered", p:visit("a.lua", 12) and not p:visit("a.lua", 12) and p:position().path == "a.lua" and p:position().line == 12)
	local root = vim.fn.tempname()
	local store = make_store(root)
	store:update(DiffProgress, DiffProgress.key("/repo"), function(x)
		x.root, x.at, x.files = p.root, p.at, p.files
	end)
	local back = store:get(DiffProgress, DiffProgress.key("/repo"))
	check("it survives the store", back:position().line == 12 and back:has_seen("a.lua", "h2") and back:badge("a.lua", "s2")[1] == "1/2", back)
	local editor_a, editor_b = DiffProgress.for_root("/repo"), DiffProgress.for_root("/repo")
	editor_a:know("x.lua", { "k1", "k2" }, "s")
	editor_a:see("x.lua", "k1")
	editor_a:visit("x.lua", 3, 100)
	editor_b:know("y.lua", { "k9" }, "s")
	editor_b:see("y.lua", "k9")
	editor_b:visit("y.lua", 7, 200)
	local stored = DiffProgress.for_root("/repo")
	stored:absorb(editor_a)
	stored:absorb(editor_b)
	check("two editors on one repo keep each other's ticks", stored:has_seen("x.lua", "k1") and stored:has_seen("y.lua", "k9"))
	check("the latest position wins", stored:position().path == "y.lua" and stored:position().line == 7)
	local older = DiffProgress.for_root("/repo")
	older:visit("x.lua", 1, 50)
	stored:absorb(older)
	check("an older position doesn't win", stored:position().path == "y.lua")
	vim.fn.delete(root, "rf")
end)

test("an expeditio lists its mandata open first, then in progress, then done", function()
	local function todo(id, state, created)
		return Mandatum:new({ id = id, state = state, created = created, expeditio = "e1", text = id })
	end
	local epic = Expeditio.make("e1", "work", "/r", nil, 1):hydrate({
		todo("done-old", "done", 1),
		todo("sent", "sent", 2),
		todo("open-new", "open", 5),
		todo("done-new", "done", 6),
		todo("open-old", "open", 3),
		todo("gone", "dropped", 4),
	})
	local ids = vim.tbl_map(function(t)
		return t.id
	end, epic:mandata())
	check("by status, oldest first within one", table.concat(ids, ",") == "open-old,open-new,sent,done-old,done-new", ids)
	check("the thread opens on the first open mandatum", expeditio_view_mapper.to_thread(expeditio_dto_mapper.to_expeditio_dto(epic), function()
		return "you"
	end, 10):latest_turn().id == "open-old")
end)

test("older code can't erase what newer code stored, and yields the poller to it", function()
	local root = vim.fn.tempname()
	local store = make_store(root)
	local Old = require("workspace.shared.lib.model").extend({ kind = "merge_requests", fields = { "id", "state", "iid" } })
	store:update(MergeRequest, "k", function(m)
		m.iid, m.head_sha, m.conflict_head = 5, "abc", "abc"
	end)
	store:update(Old, "k", function(m)
		m.iid = 6
	end)
	local back = store:get(MergeRequest, "k")
	check("fields an older model doesn't know survive its write", back.iid == 6 and back.head_sha == "abc" and back.conflict_head == "abc", back)
	vim.fn.delete(root, "rf")
	local mr = MergeRequest.for_root("/p", "b")
	check("newer code claims and stamps the record", mr:claim("/p", "b", 100, 2000) and mr.poller == 2000)
	check("older code doesn't claim a record newer code polls", not mr:claim("/p", "b", 1000, 1000))
	check("the same or newer code still does", mr:claim("/p", "b", 2000, 2000) and mr:claim("/p", "b", 3000, 3000) and mr.poller == 3000)
end)

test("workspace splits fit the room and views know when they're orphaned", function()
	check("a split that fits keeps its size", Workspace.fit(44, 347, 60, 28) == 44)
	check("a split with room to spare keeps its size", Workspace.fit(123, 200, 60, 28) == 123)
	check("the 10:02 split, 123 wide next to a 124-wide pane, shrinks to leave the editor its minimum", Workspace.fit(123, 124, 60, 28) == 63, Workspace.fit(123, 124, 60, 28))
	check("no split when even the smallest one doesn't fit", Workspace.fit(123, 80, 60, 28) == nil and Workspace.fit(10, 2, 1, 1) == nil)
	check("the 13:06 sidebar and conversation don't fit a 99-column tab", Workspace.fit(123, 99, 60, 28) == 38)
	check("infra takes a share of a full-height editor", Workspace.docker_rows(53, 53) == 18)
	check("infra fits under an editor shortened by a user split", Workspace.docker_rows(26, 53) == 9)
	check("no infra split under an editor too short for it", Workspace.docker_rows(14, 53) == nil)
	local w = Workspace:new({ id = "w1", panes = { sidebar = 50, editor = 18 } })
	check("a view the workspace knows is kept", Workspace.keeps(w, "sidebar", 50))
	check("a view spawned by a split that failed is orphaned", not Workspace.keeps(w, "sidebar", 51))
	check("a view whose workspace is gone is orphaned", not Workspace.keeps(nil, "sidebar", 50))
	check("a view without a pane id isn't judged by a missing one", not Workspace.keeps(w, "docker", nil))
end)

test("the review process is the only way to the review", function()
	local store = make_store(vim.fn.tempname())
	local root = "/w"
	local Miles = require("workspace.legio.domain.miles")
	local running = Miles:new({ id = "a1", state = "idle", root = root, branch = "feat" })
	local sent, logged = {}, {}
	local reviews = require("workspace.workflow.application.review_process").new({
		reviews = require("workspace.workflow.infrastructure.outbound.filesystem.review_repository").new(store),
		agents = {
			all = function()
				return { running }
			end,
			get = function()
				return running
			end,
		},
		messenger = {
			message = function(id, text, done)
				table.insert(sent, { id = id, text = text })
				if done then
					done(true)
				end
			end,
		},
		git = {
			code_tree = function()
				return "tree-1"
			end,
			locate = function()
				return { root = root, branch = "feat" }
			end,
			default_branch = function()
				return "main"
			end,
		},
		log = function(entry)
			table.insert(logged, entry)
		end,
		clock = function()
			return 10
		end,
	})
	local Commands = {
		save = require("workspace.workflow.application.commands.save_comment_command"),
		send = require("workspace.workflow.application.commands.send_comments_command"),
		resolve = require("workspace.workflow.application.commands.resolve_comment_command"),
		ready = require("workspace.workflow.application.commands.mark_ready_command"),
		approve = require("workspace.workflow.application.commands.approve_review_command"),
	}
	local CommentDto = require("workspace.workflow.application.dto.comment_dto")
	local view_mapper = require("workspace.workflow.presentation.mappers.review_view_mapper")
	local id = reviews:save_comment(Commands.save.new({ root = root, key = root .. "/a.lua", path = "a.lua", line1 = 3, line2 = 4, text = "rename this" }))
	local drafts = reviews:draft_comments(root)
	check("a saved comment comes back as a CommentDto", #drafts == 1 and drafts[1].id == id and drafts[1].location == "a.lua:3-4" and CommentDto.is(drafts[1]))
	local vm = view_mapper.to_comment_view_model(drafts[1])
	check("the screen maps it to a CommentViewModel with its look", vm.sign_highlight == "ReviewNoteSign" and vm.list_label:find("review", 1, true) == 1)
	local ok_unknown = pcall(Commands.save.new, { root = root, nope = 1 })
	check("a command refuses fields it doesn't have", not ok_unknown)
	check("the stored record holds plain fields", store:get_record("reviews", (root:gsub("/", "%%"))).comments[1].text == "rename this")
	local who = reviews:recipient(root)
	check("the one agent in the worktree gets the comments", who and who.id == "a1" and require("workspace.workflow.application.dto.review_recipient_dto").is(who))
	reviews:send_comments(Commands.send.new({ root = root, ids = { id }, agent_id = "a1", quote = function()
		return { "local x" }
	end, lines = { [id] = { 5, 6 } } }))
	check("sending messages the agent with the prompt", #sent == 1 and sent[1].text:find("rename this", 1, true) ~= nil and sent[1].text:find("resolve <id>", 1, true) ~= nil)
	local open = reviews:open_comments(root)
	check("a sent comment is open and keeps the moved lines", #open == 1 and open[1].line1 == 5 and open[1].line2 == 6)
	check("sending is logged", logged[1] and logged[1].event == "sent" and logged[1].session == "a1")
	check("an open comment blocks approval", not reviews:can_approve(root))
	check("an open comment blocks the agent from stopping", reviews:check_stop(event("stop"), root) ~= nil)
	local resolved = reviews:resolve(Commands.resolve.new({ root = root, id = id, reply = "renamed", session = "a1" }))
	check("the agent resolves it", resolved and resolved.state == "resolved" and resolved.reply == "renamed")
	check("ready once nothing is open", reviews:mark_ready(Commands.ready.new({ root = root, note = "done", session = "a1" })) and reviews:summary(root).ready)
	check("approving messages the agent", reviews:approve(Commands.approve.new({ root = root, agent_id = "a1" })) and reviews:summary(root).approved and sent[2].text:find("approved", 1, true) ~= nil)
	local push = reviews:check_tool_use(event("before_tool", { tool_name = "Bash", tool_input = { command = "glab mr create" } }), root)
	check("an approved, unchanged tree may open a merge request", push == nil)
	check("pushing to the default branch is blocked", reviews:check_tool_use(event("before_tool", { tool_name = "Bash", tool_input = { command = "git push origin main" } }), root) ~= nil)
	local nav, index, total = reviews:next_comment(root, nil, nil, 1)
	check("stepping through comments in files", nav and nav.id == id and index == 1 and total == 1)
end)

local features_dir = vim.fs.dirname(vim.fs.abspath(arg[0])) .. "/features"
for _, file in ipairs(vim.fn.glob(features_dir .. "/*.lua", false, true)) do
	dofile(file)({ test = test, check = check, make_store = make_store })
end

if #failures > 0 then
	io.write(("%d/%d checks failed\n"):format(#failures, count))
	for _, f in ipairs(failures) do
		io.write("  ✗ " .. f .. "\n")
	end
	os.exit(1)
end
io.write(("%d checks passed\n"):format(count))
