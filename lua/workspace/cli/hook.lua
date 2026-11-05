local nvim = require("workspace.nvim")
local hooks = require("workspace.hooks")
local models = require("workspace.models")
local Agent, Ask = models.Agent, models.Ask

local M = {}

local logger = nvim.logger("hook", {
	pid = vim.uv.os_getpid(),
	pane = tonumber(vim.env.WEZTERM_PANE or ""),
	job = vim.env.CLAUDE_JOB_DIR,
})

local function ask(s, payload)
	local id = ("%d-%d"):format(os.time(), vim.uv.os_getpid())
	local model
	s:update(Ask, id, function(a)
		local fresh = Ask.from_hook(payload, id, vim.uv.os_getpid(), nvim.clock())
		for _, f in ipairs(Ask.fields) do
			a[f] = fresh[f]
		end
	end)
	local settled = false
	local function check()
		model = s:get(Ask, id)
		settled = not model or not model:is_pending()
	end
	local watcher = vim.uv.new_fs_event()
	watcher:start(nvim.paths.dir(Ask.kind), {}, vim.schedule_wrap(check))
	check()
	vim.wait(Ask.timeout * 1000, function()
		return settled
	end)
	watcher:close()
	model = s:get(Ask, id)
	if model and model:is_pending() then
		s:update(Ask, id, function(a)
			a:expire(nvim.clock())
		end)
	end
	s:remove(Ask, id)
	if not model or model.state ~= "answered" then
		return nil
	end
	s:update(Agent, payload.session_id, function(a)
		a:apply("answer", nvim.clock())
	end)
	s:log({ type = "ask", session = model.session, root = model.cwd, kind = model.kind, tool = model.tool, input = model.input, decision = model.decision, answers = model.answers, text = model:summary(), answer = model:answer_text() })
	return model.output
end

function M.run()
	local ok, payload = pcall(nvim.json.decode, io.read("*a") or "")
	if not ok or type(payload) ~= "table" or not payload.session_id then
		return 0
	end
	local background = vim.env.CLAUDE_JOB_DIR ~= nil and vim.env.CLAUDE_JOB_DIR ~= ""
	logger.info("hook", { hook = payload.hook_event_name, tool = payload.tool_name, session = payload.session_id, background = background, pane = vim.env.WEZTERM_PANE })
	local output = hooks.handle(nvim.new_store(nil, logger), payload, { pane = vim.env.WEZTERM_PANE, background = background, ask = ask })
	if output then
		logger.info("hook.output", { hook = payload.hook_event_name, session = payload.session_id, output = output })
		io.write(nvim.json.encode(output))
	end
	return 0
end

return M
