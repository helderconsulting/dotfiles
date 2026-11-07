local mapper = require("workspace.legio.application.mappers.miles_dto_mapper")
local StartMilesCommand = require("workspace.legio.application.commands.start_miles_command")
local Miles = require("workspace.legio.domain.miles")
local Contubernium = require("workspace.legio.domain.contubernium")

local ContuberniumMembership = {}
ContuberniumMembership.__index = ContuberniumMembership

local M = {}

function M.new(ports)
	return setmetatable({
		contubernia = ports.contubernia,
		milites = ports.milites,
		todos = ports.todos,
		runner = ports.runner,
		git = ports.git,
		log = ports.log or function() end,
		clock = ports.clock or os.time,
		random = ports.random or math.random,
	}, ContuberniumMembership)
end

function ContuberniumMembership:hold_for(miles_id, text)
	self.milites:update_existing(miles_id, function(a)
		a:hold(text, self.clock())
	end)
end

function ContuberniumMembership:leave(contubernium_id, miles_id)
	local gone, decanus
	local contubernium = self.contubernia:update(contubernium_id, function(t)
		gone, decanus = t:leave(miles_id)
		if not gone then
			return false
		end
		return t:is_empty() and "delete" or true
	end)
	return contubernium, gone, decanus
end

function ContuberniumMembership:tell_the_rest(contubernium, gone, decanus, miles_id)
	for _, letter in ipairs(contubernium:news(gone, decanus, self.todos.done_command)) do
		self:hold_for(letter.miles, letter.text)
	end
	self.log({ type = "contubernium", event = "left", contubernium = contubernium.id, agent = miles_id, name = gone.name, decanus = decanus and decanus.miles })
end

function ContuberniumMembership:remove_miles(miles_id)
	for _, t in ipairs(self.contubernia:all()) do
		if t:has(miles_id) then
			local contubernium, gone, decanus = self:leave(t.id, miles_id)
			if gone and decanus then
				self.todos.reassign(contubernium.todo, miles_id, decanus.miles)
			end
			if gone and not contubernium:is_empty() then
				self:tell_the_rest(contubernium, gone, decanus, miles_id)
			end
		end
	end
end

function ContuberniumMembership:plan_gate_open(miles_id)
	local contubernium = self.contubernia:of(miles_id)
	return contubernium == nil or contubernium:plan_gate_open()
end

function ContuberniumMembership:contubernium_of(miles_id)
	local contubernium = self.contubernia:of(miles_id)
	if not contubernium then
		return nil
	end
	return mapper.to_contubernium_dto(contubernium, function(id)
		return self.milites:find(id)
	end)
end

function ContuberniumMembership:send_message(command)
	local contubernium = self.contubernia:of(command.from)
	local targets = contubernium and contubernium:recipients(command.from, command.to) or {}
	if #targets == 0 then
		return nil
	end
	local letter = contubernium:letter(command.from, command.text)
	for _, m in ipairs(targets) do
		self:hold_for(m.miles, letter)
		self.log({ type = "contubernium", event = "message", contubernium = contubernium.id, from = command.from, to = m.miles })
	end
	return mapper.to_contubernium_message_sent_dto(contubernium, targets)
end

function ContuberniumMembership:new_contubernium(command)
	local ids = {}
	for i = 1, command.size do
		ids[i] = Miles.new_id(self.random)
	end
	local name = Contubernium.pick_name(self.contubernia:all(), self.random)
	return Contubernium.make(Contubernium.new_id(self.random), command.todo_id, command.root, self.git.locate(command.root).branch, ids, self.clock(), name)
end

function ContuberniumMembership:update_contubernium(id, fn)
	return self.contubernia:update(id, function(t, created)
		if created then
			return false
		end
		return fn(t)
	end)
end

function ContuberniumMembership:start_member(contubernium, command, member, done)
	local todo = { id = command.todo_id, text = command.todo_text, done_command = self.todos.done_command }
	local start = StartMilesCommand.new({ cwd = command.root, prompt = contubernium:brief(todo, member.name), id = member.miles, provider = command.provider, model = command.model, mode = command.mode })
	self.runner:start(start, function(ok, started)
		local id = started or member.miles
		if ok then
			self:update_contubernium(contubernium.id, function(t)
				return t:started(member.name, id)
			end)
			self.milites:update_existing(id, function(a)
				a.title = Contubernium.member_title(member.name, nil, command.todo_title)
			end)
		else
			self:update_contubernium(contubernium.id, function(t)
				return t:leave(member.miles) ~= nil
			end)
		end
		done(ok, id)
	end)
end

function ContuberniumMembership:start_the_rest(contubernium, command, decanus_id)
	for i = 2, #contubernium.members do
		local member = contubernium.members[i]
		self:start_member(contubernium, command, member, function(started)
			if not started then
				self:hold_for(decanus_id, ("%s didn't start. Split the work without them; `%s list` shows who's in the contubernium."):format(member.name, Contubernium.command))
			end
		end)
	end
end

function ContuberniumMembership:start_contubernium(command, done)
	if not Contubernium.fits(command.size) then
		return done(false, ("a contubernium has %d to %d agents"):format(Contubernium.min, Contubernium.max))
	end
	local contubernium = self:new_contubernium(command)
	local decanus = contubernium:decanus()
	if not self.todos.assign(command.todo_id, decanus.miles) then
		return done(false, command.todo_title .. " was just sent from somewhere else")
	end
	self.contubernia:save(contubernium)
	self:start_member(contubernium, command, decanus, function(ok, decanus_id)
		if not ok then
			self.todos.release(command.todo_id, decanus.miles)
			self.contubernia:remove(contubernium.id)
			return done(false, "couldn't start the contubernium for " .. command.todo_title)
		end
		self.todos.send(command.todo_id, decanus_id, decanus.miles)
		self:start_the_rest(contubernium, command, decanus_id)
		done(true, mapper.to_contubernium_started_dto(contubernium, decanus_id, command.todo_title))
	end)
end

return M
