local nvim = require("workspace.nvim")
local models = require("workspace.models")
local Agent, Ask, Review = models.Agent, models.Ask, models.Review

local M = {}

M.review_command = "~/.config/wezterm/bin/review"

function M.registry()
	local entries = {}
	for _, name in ipairs(nvim.fs.list(nvim.paths.claude_sessions)) do
		local text = name:match("%.json$") and nvim.fs.read(nvim.paths.claude_sessions .. "/" .. name)
		local ok, entry = pcall(nvim.json.decode, text or "")
		if ok and type(entry) == "table" then
			table.insert(entries, entry)
		end
	end
	return models.Registry.new(entries, function(pid)
		return vim.uv.kill(pid, 0) == 0
	end)
end

local function on_message(s, payload)
	local input = payload.tool_input or {}
	local entry = input.to and M.registry():recipient(input.to)
	if not entry or not entry.sessionId then
		return
	end
	s:update(Agent, entry.sessionId, function(a)
		a:receive_message(nvim.clock())
		a.cwd = a.cwd or entry.cwd
	end)
	local text = input.message or input.content or ""
	s:log({
		type = "message",
		from_session = payload.session_id,
		from_root = payload.cwd,
		to = input.to,
		to_session = entry.sessionId,
		to_root = entry.cwd,
		text = type(text) == "string" and text or nvim.json.encode(text),
	})
end

function M.drop_asks(s, session)
	for _, a in ipairs(s:all(Ask)) do
		if a.session == session and a:is_pending() then
			s:update(Ask, a.id, function(ask)
				return ask:is_pending() and ask:dismiss(nvim.clock())
			end)
		end
	end
end

local function review_at(s, cwd)
	local place = nvim.locate(cwd or vim.uv.cwd())
	return s:get(Review, Review.key(place.root)) or Review.for_root(place.root), place.root, place
end

M.protected = { "main", "master" }

local function guard_context(root, place)
	local protected = {}
	for _, name in ipairs(M.protected) do
		protected[name] = true
	end
	local res = vim.system({ "git", "-C", root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, { text = true }):wait()
	local default = res.code == 0 and vim.trim(res.stdout or ""):match("^[^/]+/(.+)$")
	if default then
		protected[default] = true
	end
	return {
		branch = place.branch,
		protected = protected,
		tree = function()
			return nvim.code_tree(root)
		end,
	}
end

local function track(s, payload, ctx)
	local event = Agent.hook_event(payload)
	if event then
		local place = Agent.relocates_on(event) and payload.cwd and nvim.locate(payload.cwd) or nil
		s:update(Agent, payload.session_id, function(a, created)
			if place or created then
				a:locate(place or { cwd = payload.cwd })
			end
			a:bind_pane(ctx.pane or "", ctx.background)
			a.host = ctx.host or a.host
			a:note_tool(payload.hook_event_name, payload.tool_name, payload.tool_input, nvim.clock())
			if event == "prompt" then
				a:begin_turn(payload.prompt, nvim.clock())
			end
			a:apply(event, nvim.clock())
		end)
	end
	if Ask.superseded_by(event) then
		M.drop_asks(s, payload.session_id)
	end
end

function M.handle(s, payload, ctx)
	if payload.hook_event_name == "PreToolUse" and payload.tool_name == "SendMessage" then
		on_message(s, payload)
		return nil
	end
	track(s, payload, ctx)
	if Review.guards(payload) then
		local review, root, place = review_at(s, payload.cwd)
		return review:guard(payload, guard_context(root, place), M.review_command)
	elseif ctx.ask and Ask.handles(payload, ctx.background) then
		return ctx.ask(s, payload)
	elseif payload.hook_event_name == "Stop" then
		return review_at(s, payload.cwd):gate(payload, M.review_command)
	elseif payload.hook_event_name == "SessionEnd" then
		s:remove(Agent, payload.session_id)
	end
	return nil
end

return M
