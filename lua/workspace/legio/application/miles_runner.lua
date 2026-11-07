local mapper = require("workspace.legio.application.mappers.miles_dto_mapper")
local ProcessReportCommand = require("workspace.legio.application.commands.process_report_command")
local Miles = require("workspace.legio.domain.miles")
local MilesProcess = require("workspace.legio.domain.miles_process")
local Contubernium = require("workspace.legio.domain.contubernium")

local MilesRunner = {}
MilesRunner.__index = MilesRunner

local M = {}

M.continue_prompt = "continue"
M.settle_ms = 400
M.move_wait_ms = 15000

function M.new(ports)
	return setmetatable({
		milites = ports.milites,
		contubernia = ports.contubernia,
		agentd = ports.agentd,
		cli = ports.cli,
		attach = ports.attach,
		panes = ports.panes,
		sessions = ports.sessions,
		report = ports.report,
		notify = ports.notify,
		defer = ports.defer,
		folder_exists = ports.folder_exists,
		trace = ports.trace,
		clock = ports.clock or os.time,
		random = ports.random or math.random,
	}, MilesRunner)
end

local function finish(done, ...)
	if done then
		done(...)
	end
end

function MilesRunner:observe(fields)
	fields.provider = fields.provider or MilesProcess.default_provider
	self.report(ProcessReportCommand.new(fields))
end

function MilesRunner:usable_folder(cwd, done)
	if cwd and self.folder_exists(cwd) then
		return true
	end
	self.notify.warn("can't start an agent: " .. tostring(cwd) .. " is gone")
	finish(done, false)
	return false
end

function MilesRunner:fall_back(choice, cwd, prompt, resume, done)
	return function(res)
		local provider = choice.provider or self.cli.provider
		local why = res.error or "agentd failed"
		self.trace.warn("agent.fall_back", { reason = why, code = res.code, cwd = cwd })
		if res.code ~= "plan" then
			self:observe({ id = resume, provider = provider, event = "fall_back", reason = why })
		end
		if provider ~= self.cli.provider then
			self.notify.error(provider .. " needs agentd: " .. why)
			return finish(done, false)
		end
		self.notify.warn("running on " .. self.cli.label .. " instead of the sdk: " .. why)
		if self:usable_folder(cwd, done) then
			self.cli.start(self.cli.launch_args(choice, resume), cwd, prompt, done)
		end
	end
end

function MilesRunner:launch(cwd, prompt, resume, done, choice)
	if not self:usable_folder(cwd, done) then
		return
	end
	choice = choice or {}
	local fall_back = self:fall_back(choice, cwd, prompt, resume, done)
	local req = { op = "start", provider = choice.provider or self.cli.provider, id = choice.id, cwd = cwd, prompt = prompt, resume = resume, model = choice.model, mode = choice.mode }
	self.agentd.call(req, function(ok, res)
		if not ok then
			return fall_back(res)
		end
		self.trace.info("agent.start", { runtime = "sdk", id = res.id, cwd = cwd })
		finish(done, true, res.id)
	end)
end

function MilesRunner:start(command, done)
	self:launch(command.cwd, command.prompt, nil, done, { id = command.id, provider = command.provider, model = command.model, mode = command.mode })
end

local function cleared_on_success(self, id, done)
	return function(ok, ...)
		if ok == true then
			self.milites:update_existing(id, function(a)
				a:clear_stop()
				return true
			end)
		end
		finish(done, ok, ...)
	end
end

function MilesRunner:resume(command, done)
	self:launch(command.cwd, command.prompt, command.miles_id, cleared_on_success(self, command.miles_id, done))
end

function MilesRunner:new_miles_id()
	return Miles.new_id(self.random)
end

local channels = { sdk = {}, pane = {}, attach = {} }

function channels.sdk.send(self, miles, text, done)
	self.agentd.call({ op = "send", id = miles.id, text = text }, function(ok, res)
		if ok then
			return done(true)
		end
		self:observe({ id = miles.id, event = "lose", reason = res.error })
		self:launch(miles.root or miles.cwd, text, miles.id, done)
	end)
end

function channels.sdk.interrupt(self, miles, done)
	self.agentd.call({ op = "interrupt", id = miles.id }, function(ok)
		done(ok)
	end)
end

function channels.pane.send(self, miles, text, done)
	self.panes.send_keys(miles.pane, text, true, function(ok)
		if not ok then
			return done(false)
		end
		self.defer(function()
			self.panes.send_keys(miles.pane, "\r", false, done)
		end, 150)
	end)
end

function channels.pane.interrupt(self, miles, done)
	self.panes.send_keys(miles.pane, "\27", false, function(ok)
		self.defer(function()
			done(ok)
		end, M.settle_ms)
	end)
end

function channels.attach.send(self, miles, text, done)
	self.attach.send(miles.id, text, done)
end

function channels.attach.interrupt(self, miles, done)
	self.attach.keys(miles.id, "\27", function(ok)
		self.defer(function()
			done(ok)
		end, M.settle_ms)
	end)
end

function MilesRunner:channel(miles)
	return (self.milites:get(miles.id) or miles):channel()
end

function MilesRunner:send(miles, text, done)
	if miles:wants_resume() then
		self.trace.info("agent.message.resume", { agent = miles.id, hosted = miles:is_hosted(), length = #text })
		return self:launch(miles.root or miles.cwd, text, miles.id, cleared_on_success(self, miles.id, done))
	end
	local ok, why = miles:can_receive()
	if not ok then
		self.notify.warn(why)
		return finish(done, false)
	end
	local channel = self:channel(miles)
	self.trace.info("agent.message", { agent = miles.id, channel = channel, pane = miles.pane, length = #text })
	channels[channel].send(self, miles, text, function(sent)
		if not sent then
			self.trace.error("agent.message.failed", { agent = miles.id, channel = channel })
		else
			self.milites:update(miles.id, function(a)
				a:start_sending(text, self.clock())
			end)
		end
		finish(done, sent)
	end)
end

function MilesRunner:message_text(id, text, done)
	local miles = self.milites:get(id)
	if not miles then
		return finish(done, false)
	end
	self:send(miles, text, done)
end

function MilesRunner:message(command, done)
	self:message_text(command.miles_id, command.text, done)
end

function MilesRunner:continue(miles_id, done)
	self:message_text(miles_id, M.continue_prompt, function(sent)
		if sent then
			self.milites:update(miles_id, function(a)
				return a:continue(self.clock())
			end)
		end
		finish(done, sent)
	end)
end

function MilesRunner:hold_text(id, text, done)
	self.milites:update(id, function(a)
		a:hold(text, self.clock())
	end)
	self.trace.info("agent.hold", { agent = id, length = #text })
	finish(done, true, "held")
end

function MilesRunner:take_held(id, pick)
	local out
	self.milites:update(id, function(a)
		out = pick(a)
		return out ~= nil
	end)
	return out
end

function MilesRunner:release(miles_id)
	local out = self:take_held(miles_id, function(a)
		return a:release()
	end)
	if not out then
		return
	end
	self:message_text(miles_id, out.text, function(sent)
		if not sent then
			self.milites:update(miles_id, function(a)
				a:hold(out.text, out.at)
			end)
		end
	end)
end

function MilesRunner:send_now(command)
	local miles = self.milites:get(command.miles_id)
	local out = miles and self:take_held(command.miles_id, function(a)
		return a:take(command.message_id)
	end)
	if not out then
		return
	end
	self:interrupt_miles(miles, function()
		self:message_text(command.miles_id, out.text)
	end)
end

function MilesRunner:interrupt_miles(miles, done)
	channels[self:channel(miles)].interrupt(self, miles, done or function() end)
end

function MilesRunner:interrupt(miles_id, done)
	local miles = self.milites:get(miles_id)
	if not miles then
		return finish(done, false)
	end
	self:interrupt_miles(miles, done)
end

function MilesRunner:rehold(id, held)
	self.milites:update(id, function(a)
		for _, m in ipairs(held) do
			a:hold(m.text, m.at)
		end
		return #held > 0
	end)
end

function MilesRunner:revive(miles, done)
	if miles:was_stopped_on_purpose() then
		return finish(done, false, "stood down on purpose")
	end
	local held = self:take_held(miles.id, function(a)
		local out = {}
		while #a:held() > 0 do
			table.insert(out, a:take(nil))
		end
		return #out > 0 and out or nil
	end)
	if not held then
		return finish(done, false, "nothing is waiting")
	end
	local texts = {}
	for _, m in ipairs(held) do
		table.insert(texts, m.text)
	end
	self.trace.info("agent.revive", { agent = miles.id, orders = #held })
	self:launch(miles.root or miles.cwd, table.concat(texts, "\n\n"), miles.id, function(ok, why)
		if not ok then
			self:rehold(miles.id, held)
		end
		finish(done, ok, why)
	end)
end

function MilesRunner:resume_on_sdk(id, cwd, held, done)
	self:launch(cwd, nil, id, function(ok)
		if ok then
			self:rehold(id, held)
		end
		finish(done, ok, not ok and "the resume failed" or nil)
	end)
end

function MilesRunner:move_to_sdk(miles_id, done)
	local miles = self.milites:get(miles_id)
	if not miles then
		return finish(done, false, "it isn't running")
	end
	local id, cwd, held = miles.id, miles.root or miles.cwd, miles:held()
	self.trace.info("agent.move", { agent = id, cwd = cwd })
	self.attach.close(id)
	self.cli.stop(miles:short(), function(stopped)
		if not stopped then
			return finish(done, false, "couldn't stop the cli session")
		end
		self.sessions.when_gone(id, M.move_wait_ms, function(gone)
			if not gone then
				return finish(done, false, "the cli session didn't stop")
			end
			self:resume_on_sdk(id, cwd, held, done)
		end)
	end)
end

function MilesRunner:stop(miles_id, done, reason)
	if reason then
		self.milites:update_existing(miles_id, function(a)
			a:stop_on_purpose(reason, self.clock())
			return true
		end)
	end
	local ended = self.milites:update(miles_id, function(a)
		return a:apply("end", self.clock())
	end)
	local miles = self.milites:get(miles_id) or ended
	if miles:channel() == "sdk" then
		return self.agentd.call({ op = "stop", id = miles.id }, function(ok)
			finish(done, ok)
		end)
	end
	self.attach.close(miles.id)
	self.cli.stop(miles:short(), done)
end

function MilesRunner:set_mode(command, done)
	local miles = self.milites:get(command.miles_id)
	if not (miles and miles:channel() == "sdk") then
		return finish(done, false)
	end
	self.agentd.call({ op = "mode", id = miles.id, mode = command.mode }, function(ok, res)
		if not ok then
			self.notify.warn("couldn't switch mode: " .. tostring(res.error))
		end
		finish(done, ok)
	end)
end

function MilesRunner:set_model(command, done)
	local miles = self.milites:get(command.miles_id)
	if not miles then
		return finish(done, false)
	end
	local function changed(ok)
		if ok then
			self:observe({ id = miles.id, event = "model", model = command.model })
		end
		finish(done, ok)
	end
	local channel = miles:channel()
	if channel ~= "sdk" then
		return channels[channel].send(self, miles, "/model " .. command.model, changed)
	end
	self.agentd.call({ op = "model", id = miles.id, model = command.model }, function(ok, res)
		if not ok then
			self.notify.warn("couldn't switch model: " .. tostring(res.error))
		end
		changed(ok)
	end)
end

function MilesRunner:cli_catalog()
	local models = {}
	for i, m in ipairs(self.cli.models) do
		models[i] = { value = m, label = m }
	end
	return { mapper.to_model_catalog_dto(self.cli.provider, models) }
end

function MilesRunner:catalog(cwd, done)
	self.agentd.call({ op = "catalog", cwd = cwd }, function(ok, res)
		done(ok and mapper.to_model_catalog_dtos(res.providers) or self:cli_catalog())
	end)
end

function MilesRunner:setup(miles_id)
	local miles = self.milites:get(miles_id)
	return mapper.to_miles_setup_dto(miles and miles:provider() or self.cli.provider, miles and miles:model_name(), miles and miles:mode())
end

function MilesRunner:models(miles_id, done)
	local miles = self.milites:get(miles_id)
	if not (miles and miles:channel() == "sdk") then
		return done(self:cli_catalog())
	end
	local provider = miles:provider() or self.cli.provider
	self.agentd.call({ op = "models", id = miles.id }, function(ok, res)
		done({ mapper.to_model_catalog_dto(provider, ok and res.models or {}) })
	end)
end

function MilesRunner:deliver(command, done)
	if not command.miles_id then
		return self:launch(command.cwd, command.text, nil, done, { provider = command.provider, model = command.model, mode = command.mode })
	end
	local miles = self.milites:get(command.miles_id)
	if not (miles and miles:is_running()) then
		return self:launch(command.cwd or (miles and miles.root), command.text, command.miles_id, done)
	elseif miles:is_busy() then
		return self:hold_text(miles.id, command.text, done)
	end
	local ok, why = miles:can_receive()
	if not ok then
		self.notify.warn(why)
		return finish(done, false)
	end
	self:send(miles, command.text, done)
end

function MilesRunner:set_title(command)
	local title = command.title
	local contubernium = command.as_member and self.contubernia:of(command.miles_id)
	if contubernium then
		title = Contubernium.member_title(contubernium:member_for(command.miles_id).name, title)
	end
	local update = command.create and self.milites.update or self.milites.update_existing
	update(self.milites, command.miles_id, function(a)
		a.title = title
	end)
end

function MilesRunner:mark_read(command)
	local miles = self.milites:find(command.miles_id)
	if not miles or miles:is_read(command.at) then
		return
	end
	self.milites:update(command.miles_id, function(a)
		return a:mark_read(command.at)
	end)
end

function MilesRunner:watch_agentd()
	self.agentd.hold()
end

return M
