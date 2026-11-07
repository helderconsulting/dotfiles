local nvim = require("workspace.shared.adapters.nvim")
local composition_root = require("workspace.composition_root")
local mapper = require("workspace.legio.infrastructure.inbound.mappers.session_event_cli_mapper")

local M = {}

M.poll_ms = 50

local logger = nvim.logger("session_event", {
	pid = vim.uv.os_getpid(),
	pane = tonumber(vim.env.WEZTERM_PANE or ""),
	job = require("workspace.shared.providers").current().job_dir(),
})

local function watch(questions, id)
	local seen = { settled = false, shown = false }
	function seen.check()
		seen.question = questions:state(id)
		seen.settled = not seen.question or not seen.question.pending
		seen.shown = seen.settled or not seen.question.unseen
		return seen
	end
	return seen.check()
end

local function wait_until(ms, cond)
	vim.wait(ms, cond, M.poll_ms)
end

local function wait_for_answer(questions, payload)
	if not questions:has_viewer(payload.session_id, payload.cwd) then
		logger.info("question.no_viewer", { session = payload.session_id, cwd = payload.cwd })
		return nil
	end
	local timing = questions:timing()
	local id = questions:open(mapper.to_open_question_command(payload, vim.uv.os_getpid()))
	local seen = watch(questions, id)
	wait_until(timing.show_within * 1000, function()
		return seen.check().shown
	end)
	if not seen.shown then
		questions:withdraw(mapper.to_dismiss_unseen_command(id))
		seen.check()
		logger.info("question.unseen", { id = id, session = payload.session_id, state = seen.question and seen.question.state })
	end
	wait_until(timing.timeout * 1000, function()
		return seen.check().settled
	end)
	questions:expire(id)
	return mapper.to_answer(questions:close(id))
end

function M.run()
	local ok, raw = pcall(nvim.json.decode, io.read("*a") or "")
	if not ok or type(raw) ~= "table" or not raw.session_id then
		return 0
	end
	local payload = require("workspace.shared.providers").current().session_event(raw)
	local background = require("workspace.shared.providers").current().in_background()
	logger.info("session_event", { hook = payload.moment, tool = payload.tool_name, session = payload.session_id, background = background, pane = vim.env.WEZTERM_PANE })
	local services = composition_root.build(nvim.new_store(nil, logger), { clock = nvim.clock })
	local ask = function(p)
		return wait_for_answer(services.miles_questions, p)
	end
	local output = services.miles_session_events:apply(mapper.to_session_event_command(payload, vim.env.WEZTERM_PANE, background, ask))
	if output then
		logger.info("session_event.output", { hook = payload.moment, session = payload.session_id, output = output })
		io.write(nvim.json.encode(output))
	end
	return 0
end

return M
