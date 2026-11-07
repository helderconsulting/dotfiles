local nvim = require("workspace.shared.adapters.nvim")
local observer = require("workspace.shared.state.observer")
local stored_kinds = require("workspace.stored_kinds")
local composition_root = require("workspace.composition_root")
local mapper = require("workspace.legio.infrastructure.inbound.mappers.agentd_message_mapper")

local Handler = {}
Handler.__index = Handler

function Handler.new(store, reply)
	local services = composition_root.build(store, { clock = nvim.clock })
	return setmetatable({ events = services.miles_session_events, questions = services.miles_questions, legio_process = services.legio_process, reply = reply, waiting = {} }, Handler)
end

function Handler:on_session_event(msg)
	return self.events:apply(mapper.to_session_event_command(msg.payload))
end

function Handler:on_session_started(msg)
	return self.events:apply(mapper.to_session_started_command(msg))
end

function Handler:on_process_report(msg)
	self.events:receive_report(mapper.to_process_report_command(msg.report))
end

function Handler:on_question(msg, reply_id)
	local ask_id = self.questions:ask(mapper.to_ask_question_command(msg))
	self.waiting[ask_id] = { reply = reply_id, request = msg.request }
	return nil, true
end

function Handler:reply_if_answered(ask_id)
	local wait = ask_id and self.waiting[ask_id]
	if not wait then
		return
	end
	local answered = self.questions:reply(ask_id)
	if not answered then
		return
	end
	self.waiting[ask_id] = nil
	self.reply(wait.reply, answered.result)
end

function Handler:on_question_withdrawn(msg)
	for ask_id, wait in pairs(self.waiting) do
		if wait.request == msg.request then
			self.questions:withdraw(mapper.to_withdraw_question_command(ask_id))
			self:reply_if_answered(ask_id)
		end
	end
end

function Handler:on_sessions_running(msg)
	self.events:sessions_running(mapper.to_sessions_running_command(msg))
end

Handler.ops = {
	hook = Handler.on_session_event,
	started = Handler.on_session_started,
	runtime = Handler.on_process_report,
	ask = Handler.on_question,
	cancel = Handler.on_question_withdrawn,
	sync = Handler.on_sessions_running,
}

function Handler:dispatch(msg)
	local op = Handler.ops[msg.op]
	if not op then
		return self.reply(msg.id, nil, "unknown op " .. tostring(msg.op))
	end
	local ok, result, deferred = pcall(op, self, msg, msg.id)
	if not ok then
		return self.reply(msg.id, nil, tostring(result))
	end
	if msg.id and not deferred then
		self.reply(msg.id, result)
	end
end

local function read_lines(handler, on_end)
	local partial = ""
	local stdin = vim.uv.new_pipe(false)
	stdin:open(0)
	stdin:read_start(function(err, data)
		if err or not data then
			return vim.schedule(on_end)
		end
		partial = partial .. data
		local lines = vim.split(partial, "\n", { plain = true })
		partial = table.remove(lines)
		vim.schedule(function()
			for _, line in ipairs(lines) do
				local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
				if ok and type(msg) == "table" then
					handler:dispatch(msg)
				end
			end
		end)
	end)
end

function Handler.run()
	local live = observer.start(stored_kinds.all)
	local stdout = vim.uv.new_pipe(false)
	stdout:open(1)
	local function reply(id, result, err)
		if id then
			stdout:write(vim.json.encode({ id = id, result = result == nil and vim.NIL or result, error = err }) .. "\n")
		end
	end
	local handler = Handler.new(live.store, reply)
	live.bus.on("asks", function(change)
		handler:reply_if_answered(change.id)
	end)
	local lapse = vim.uv.new_timer()
	lapse:start(30000, 30000, vim.schedule_wrap(function()
		handler.legio_process:lapse_auxilia()
	end))
	local finished = false
	read_lines(handler, function()
		handler:on_sessions_running({ sessions = {} })
		finished = true
	end)
	vim.wait(2 ^ 31, function()
		return finished
	end)
	lapse:stop()
	lapse:close()
	return 0
end

return Handler
