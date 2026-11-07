local unpack = table.unpack or unpack
local mapper = require("workspace.legio.application.mappers.legio_dto_mapper")
local StartMilesCommand = require("workspace.legio.application.commands.start_miles_command")
local ResumeMilesCommand = require("workspace.legio.application.commands.resume_miles_command")
local Legio = require("workspace.legio.domain.legio")
local Cohors = require("workspace.legio.domain.cohors")
local PostResolver = require("workspace.legio.domain.post_resolver")
local Centuria = require("workspace.legio.domain.centuria")
local Contubernium = require("workspace.legio.domain.contubernium")
local muster = require("workspace.legio.domain.muster")
local chain_of_command = require("workspace.legio.domain.chain_of_command")
local Miles = require("workspace.legio.domain.miles")
local MilesProcess = require("workspace.legio.domain.miles_process")

local LegioProcess = {}
LegioProcess.__index = LegioProcess

local M = {}

function M.new(ports)
	return setmetatable({
		legio_repository = ports.legiones,
		cohortes = ports.cohortes,
		centuriae = ports.centuriae,
		contubernia = ports.contubernia,
		milites = ports.milites,
		runner = ports.runner,
		handover = ports.handover,
		revive_log = {},
		git = ports.git,
		todos = ports.todos,
		expeditiones = ports.expeditiones,
		log = ports.log or function() end,
		clock = ports.clock or os.time,
		random = ports.random or math.random,
	}, LegioProcess)
end

function LegioProcess:raise_legiones()
	for _, standing in ipairs(Legio.missing(self.legio_repository:all())) do
		self.legio_repository:save(Legio.raise(standing, self.clock()))
	end
end

function LegioProcess:find_miles(id)
	return id and self.milites:get(id) or nil
end

function LegioProcess:contubernia_of(centuria)
	local by_id = {}
	for _, c in ipairs(self.contubernia:all()) do
		by_id[c.id] = c
	end
	local out = {}
	for _, id in ipairs(centuria.contubernia) do
		table.insert(out, by_id[id])
	end
	return out
end

function LegioProcess:cohors_unit(legio)
	local centuria = legio.centuria and self.centuriae:get(legio.centuria)
	if not centuria then
		return nil
	end
	local find = function(id)
		return self:find_miles(id)
	end
	local unit = mapper.to_centuria_unit(centuria, self:contubernia_of(centuria), find)
	local cohors = centuria.cohors and self.cohortes:get(centuria.cohors)
	local led = cohors and cohors:is_led_by(find(cohors.primus_pilus))
	return led and mapper.to_cohors_unit(cohors, unit, find) or unit, centuria.title
end

function LegioProcess:legiones()
	local list = self.legio_repository:all()
	table.sort(list, Legio.order)
	local out = {}
	for _, legio in ipairs(list) do
		table.insert(out, mapper.to_legio_dto(legio, self:cohors_unit(legio)))
	end
	return out
end

local function open_mandata(expeditio)
	local out = {}
	for _, m in ipairs(expeditio.mandata) do
		if m.state == "open" then
			table.insert(out, m)
		end
	end
	return out
end

function LegioProcess:taken_names(legio)
	local out = {}
	for _, m in ipairs(self.milites:plain_all()) do
		if m.legio == legio.id and m.roman_name then
			table.insert(out, m.roman_name)
		end
	end
	return out
end

function LegioProcess:veterans(legio)
	local out = {}
	for _, m in ipairs(self.milites:plain_all()) do
		if m.legio == legio.id and m.roman_name and m.state ~= "fallen" and not m:is_running() and m:is_veteran() then
			table.insert(out, m)
		end
	end
	table.sort(out, Miles.by_seniority)
	local list = {}
	for _, m in ipairs(out) do
		table.insert(list, { id = m.id, name = m.roman_name, rank = m:rank() })
	end
	return list
end

function LegioProcess:new_id(exists, make)
	local id = make(self.random)
	while exists(id) do
		id = make(self.random)
	end
	return id
end

function LegioProcess:plan(legio, expeditio, mandata)
	local contubernia = self.contubernia:all()
	local taken = {}
	for _, c in ipairs(contubernia) do
		taken[c.id] = true
	end
	local cohors = self.cohortes:get(Cohors.key(expeditio.root))
	return muster.plan(legio, expeditio, {
		new_primus_pilus = not (cohors and cohors:is_led_by(self:find_miles(cohors.primus_pilus))),
		commander_commits = cohors ~= nil and cohors.commander_commits == true,
		mandata = mandata,
		taken_names = self:taken_names(legio),
		veterans = self:veterans(legio),
		contubernia = contubernia,
		base = self.git.locate(expeditio.root).branch,
		at = self.clock(),
		random = self.random,
		done_command = self.todos.done_command,
		new_id = function()
			return self.runner:new_miles_id()
		end,
		centuria_id = self:new_id(function(id)
			return self.centuriae:get(id) ~= nil
		end, Centuria.new_id),
		new_contubernium_id = function()
			local id = self:new_id(function(id)
				return taken[id]
			end, Contubernium.new_id)
			taken[id] = true
			return id
		end,
	})
end

function LegioProcess:assign(squads)
	local assigned = {}
	for _, s in ipairs(squads) do
		local decanus = s.contubernium:decanus().miles
		if not self.todos.assign(s.mandatum.id, decanus) then
			for _, done in ipairs(assigned) do
				self.todos.release(done.mandatum.id, done.contubernium:decanus().miles)
			end
			return false, s.mandatum.title .. " was just sent from somewhere else"
		end
		table.insert(assigned, s)
	end
	return true
end

function LegioProcess:muster(legio, expeditio, plan)
	local at = self.clock()
	for _, s in ipairs(plan.squads) do
		self.contubernia:save(s.contubernium)
	end
	self.centuriae:save(plan.centuria)
	self.cohortes:update(Cohors.key(expeditio.root), function(c, created)
		if created then
			c.root, c.created = expeditio.root, at
		end
		if plan.primus_pilus then
			c:release()
		end
		local led = plan.primus_pilus and c:lead(plan.primus_pilus.id)
		return c:join(plan.centuria.id) or led
	end)
	self.legio_repository:update_existing(legio.id, function(l)
		return l:deploy(expeditio.id, expeditio.title, plan.centuria.id, at)
	end)
end

function LegioProcess:enlist(legio, root, p)
	self.milites:update(p.id, function(m)
		m:enlist(legio.id, p.post, p.name, root)
		m.title = muster.title(p)
	end)
	if p.mandatum then
		self.todos.send(p.mandatum, p.id, p.id)
	end
end

function LegioProcess:start_post(legio, root, p, launch, done)
	local function finish(ok)
		if ok then
			self:enlist(legio, root, p)
		elseif p.mandatum then
			self.todos.release(p.mandatum, p.id)
		end
		self.log({ type = "legio", event = ok and "enlisted" or "failed", legio = legio.id, miles = p.id, name = p.name, post = p.post, resumed = p.resume })
		done(ok)
	end
	if p.resume then
		return self.runner:resume(ResumeMilesCommand.new({ miles_id = p.id, cwd = root, prompt = p.prompt }), finish)
	end
	self.runner:start(StartMilesCommand.new({ cwd = root, prompt = p.prompt, id = p.id, provider = launch.provider, model = p.model, mode = launch.mode }), finish)
end

function LegioProcess:start_posts(legio, expeditio, plan, launch, done)
	local waiting, started = #plan.posts, 0
	for _, p in ipairs(plan.posts) do
		self:start_post(legio, expeditio.root, p, launch, function(ok)
			started = started + (ok and 1 or 0)
			waiting = waiting - 1
			if waiting == 0 then
				done(started)
			end
		end)
	end
end

function LegioProcess:deploy(command, done)
	local legio = self.legio_repository:get(command.legio_id)
	if not legio then
		return done(false, "no legio " .. tostring(command.legio_id))
	end
	local can, why = legio:can_deploy()
	if not can then
		return done(false, why)
	end
	local expeditio = self.expeditiones.get(command.expeditio_id)
	if not expeditio then
		return done(false, "no expeditio " .. tostring(command.expeditio_id))
	end
	local mandata = open_mandata(expeditio)
	if #mandata == 0 then
		return done(false, expeditio.title .. " has no open mandata")
	end
	local plan = self:plan(legio, expeditio, mandata)
	local assigned, reason = self:assign(plan.squads)
	if not assigned then
		return done(false, reason)
	end
	self:muster(legio, expeditio, plan)
	self.log({ type = "legio", event = "deployed", legio = legio.id, expeditio = expeditio.id, size = #plan.posts })
	local launch = { provider = command.provider or MilesProcess.default_provider, mode = command.mode or MilesProcess.default_mode }
	self:start_posts(legio, expeditio, plan, launch, function(started)
		if started == 0 then
			self:withdraw(legio, plan)
			return done(false, "no miles of " .. legio.name .. " started")
		end
		done(true, mapper.to_deployed_dto(legio, expeditio, started, plan.centuria.centurio))
	end)
end

function LegioProcess:credit(legio_id, ids, finish)
	for _, id in ipairs(ids) do
		local promoted, name
		self.milites:update_existing(id, function(m)
			local added, rank = finish(m)
			promoted, name = rank, m.roman_name or m:display_name()
			return added
		end)
		if promoted then
			self.legio_repository:update_existing(legio_id, function(l)
				return l:record(("%s became %s"):format(name, promoted), self.clock())
			end)
		end
	end
end

local function members(contubernium, also)
	local out = { also }
	for _, m in ipairs(contubernium and contubernium.members or {}) do
		if m.miles ~= also then
			table.insert(out, m.miles)
		end
	end
	return out
end

function LegioProcess:credit_mandata(legio, expeditio, contubernia)
	local finished = 0
	for _, m in ipairs(expeditio.mandata) do
		if m.state == "done" then
			finished = finished + 1
			self:credit(legio.id, members(Contubernium.for_todo(contubernia, m.id), m.assignee), function(miles)
				return miles:finish_mandatum(m.id)
			end)
		end
	end
	return finished == #expeditio.mandata
end

function LegioProcess:cohors_idle_without(legio, cohors_id)
	for _, other in ipairs(self.legio_repository:all()) do
		local centuria = other.id ~= legio.id and other:is_deployed() and self.centuriae:get(other.centuria)
		if centuria and centuria.cohors == cohors_id then
			return false
		end
	end
	return true
end

function LegioProcess:release_primus_pilus(legio, centuria)
	local cohors = centuria and centuria.cohors and self.cohortes:get(centuria.cohors)
	if not (cohors and cohors:has_leader() and self:cohors_idle_without(legio, cohors.id)) then
		return nil
	end
	local id = cohors:is_led_by(self:find_miles(cohors.primus_pilus)) and cohors.primus_pilus or nil
	self.cohortes:update_existing(cohors.id, function(c)
		c:release()
	end)
	return id
end

function LegioProcess:end_expeditio(legio, expeditio, contubernia)
	local centuria = self.centuriae:get(legio.centuria)
	local ids = centuria and { centuria.centurio, centuria.optio } or {}
	for _, c in ipairs(contubernia) do
		if centuria and c.centuria == centuria.id then
			for _, id in ipairs(members(c)) do
				table.insert(ids, id)
			end
		end
	end
	self:credit(legio.id, ids, function(miles)
		return miles:finish_expeditio(expeditio.id)
	end)
	local running = {}
	table.insert(ids, self:release_primus_pilus(legio, centuria))
	for _, id in ipairs(ids) do
		local miles = self.milites:find(id)
		if miles and miles:is_running() then
			table.insert(running, id)
		end
	end
	local account = centuria and centuria.account and { by = self:name_of(centuria.account.by), text = centuria.account.text }
	self.legio_repository:update_existing(legio.id, function(l)
		l:discharge(expeditio.title, self.clock())
		if account then
			l:record(("%s's account: %s"):format(account.by, account.text), self.clock())
		end
		return l:record(("missio: %d milites stood down"):format(#running), self.clock())
	end)
	self.log({ type = "legio", event = "discharged", legio = legio.id, expeditio = expeditio.id, stood_down = #running })
	return running
end

local function caller_last(ids, caller)
	local out, last = {}, nil
	for _, id in ipairs(ids) do
		if id == caller then
			last = id
		else
			table.insert(out, id)
		end
	end
	table.insert(out, last)
	return out
end

function LegioProcess:stand_down(ids, done)
	local i = 0
	local function next_one()
		i = i + 1
		if not ids[i] then
			return done()
		end
		self.runner:stop(ids[i], next_one, "stood_down")
	end
	next_one()
end

function LegioProcess:credit_finished(caller, done)
	local contubernia = self.contubernia:all()
	local stops = {}
	for _, legio in ipairs(self.legio_repository:all()) do
		local expeditio = legio:is_deployed() and self.expeditiones.get(legio.expeditio)
		if expeditio and self:credit_mandata(legio, expeditio, contubernia) and #expeditio.mandata > 0 then
			for _, id in ipairs(self:end_expeditio(legio, expeditio, contubernia)) do
				table.insert(stops, id)
			end
		end
	end
	self:stand_down(caller_last(stops, caller), done or function() end)
end

function LegioProcess:centuria_of(id)
	local contubernium = self.contubernia:of(id)
	if contubernium and contubernium.centuria then
		return self.centuriae:get(contubernium.centuria)
	end
	for _, centuria in ipairs(self.centuriae:all()) do
		if centuria:post_of(id) then
			return centuria
		end
	end
end

function LegioProcess:name_for(miles)
	local m = miles and self.milites:find(miles)
	return m and (m.roman_name or m:display_name()) or nil
end

function LegioProcess:cohors_led_by(id)
	for _, cohors in ipairs(self.cohortes:all()) do
		if cohors.primus_pilus == id and cohors:is_led_by(self:find_miles(id)) then
			return cohors
		end
	end
end

function LegioProcess:chain_of(id)
	local led = id and self:cohors_led_by(id)
	if led then
		local centuriae = {}
		local deployed = {}
		for _, legio in ipairs(self.legio_repository:all()) do
			if legio:is_deployed() and legio.centuria then
				deployed[legio.centuria] = true
			end
		end
		for _, centuria_id in ipairs(led.centuriae) do
			local centuria = deployed[centuria_id] and self.centuriae:get(centuria_id)
			if centuria then
				table.insert(centuriae, centuria)
			end
		end
		return chain_of_command.of_primus_pilus(centuriae, function(miles)
			return self:name_for(miles)
		end)
	end
	local centuria = id and self:centuria_of(id)
	if not centuria then
		return nil
	end
	local cohors = centuria.cohors and self.cohortes:get(centuria.cohors)
	local leader = cohors and cohors:is_led_by(self:find_miles(cohors.primus_pilus)) and { miles = cohors.primus_pilus, name = self:name_for(cohors.primus_pilus) } or nil
	return chain_of_command.of(id, centuria, self:contubernia_of(centuria), function(miles)
		return self:name_for(miles)
	end, leader)
end

function LegioProcess:name_of(id)
	local m = self.milites:find(id)
	return m and (m.roman_name or m:display_name()) or id
end

function LegioProcess:deliver(recipients, text)
	local names, stood_down = {}, {}
	for _, r in ipairs(recipients) do
		local miles = self.milites:find(r.miles)
		if miles and miles:was_stopped_on_purpose() then
			table.insert(stood_down, r.name)
		else
			self.runner:hold_text(r.miles, text)
			table.insert(names, r.name)
		end
	end
	self:revive_waiting()
	return names, stood_down
end

local REVIVE_GAP, REVIVE_LIMIT = 600, 2

local REVIVE_REASONS = {
	context_full = "your context is full",
	resume_failed = "it could not be resumed",
	attempts_exhausted = "it stopped again after resuming",
}

function LegioProcess:revivable(miles)
	if miles:is_running() or miles:was_stopped_on_purpose() or #miles:held() == 0 or not miles.legio then
		return false
	end
	local legio = self.legio_repository:get(miles.legio)
	return legio ~= nil and legio:is_deployed()
end

function LegioProcess:revive_waiting()
	local now = self.clock()
	for _, miles in ipairs(self.milites:all()) do
		if self:revivable(miles) then
			self:revive_one(miles, now)
		end
	end
end

function LegioProcess:revive_one(miles, now)
	local fraction = miles:context_fraction()
	if fraction and fraction >= Miles.handover_at then
		return self:replace(miles, "context_full")
	end
	local log = self.revive_log[miles.id] or { count = 0, at = 0 }
	if log.count > 0 and now - log.at < REVIVE_GAP then
		return
	end
	if log.count >= REVIVE_LIMIT then
		return self:replace(miles, "attempts_exhausted")
	end
	self.revive_log[miles.id] = { count = log.count + 1, at = now }
	self.runner:revive(miles, function(ok)
		if ok then
			self.revive_log[miles.id] = nil
			self.log({ type = "legio", event = "revived", miles = miles.id, reason = "resumed" })
			return
		end
		local attempt = self.revive_log[miles.id] or log
		if attempt.count >= REVIVE_LIMIT then
			return self:replace(miles, "attempts_exhausted")
		end
		self.log({ type = "legio", event = "revive_retry", miles = miles.id, reason = "resume_failed", attempt = attempt.count })
	end)
end

function LegioProcess:replace(miles, reason)
	if miles:was_stopped_on_purpose() then
		return
	end
	local texts = {}
	self.runner:take_held(miles.id, function(a)
		while #a:held() > 0 do
			table.insert(texts, a:take(nil).text)
		end
		return #texts > 0 or nil
	end)
	self.log({ type = "legio", event = "replaced", miles = miles.id, reason = reason })
	if not self.handover then
		return
	end
	self.handover.hand_over({
		miles_id = miles.id,
		traditio = ("Your session stopped: %s. These orders were waiting for you:\n\n%s"):format(REVIVE_REASONS[reason] or reason, table.concat(texts, "\n\n")),
	}, function(ok, why)
		self.log({ type = "legio", event = ok and "replaced_handed_over" or "replace_failed", miles = miles.id, reason = reason, why = why })
	end)
end

local function report_as_auxilium(self, sender, command)
	if not sender:is_running() then
		return nil, "your session has ended"
	end
	local caller = self.milites:find(sender.caller)
	local names, stood_down = {}, {}
	if caller then
		local text = ("%s reports: %s"):format(self:name_of(command.from), command.text)
		names, stood_down = self:deliver({ { miles = sender.caller, name = self:name_of(sender.caller) } }, text)
	end
	self.log({ type = "legio", event = "auxilium_report", from = sender.id, to = sender.caller })
	self.milites:update_existing(sender.id, function(m)
		m.due = nil
	end)
	self.runner:stop(sender.id, function() end, "auxilium_done")
	if not caller then
		return nil, "the miles who called you is gone"
	end
	return names, stood_down
end

function LegioProcess:call_auxilium(command, done)
	local caller = self:find_miles(command.from)
	if caller and caller:is_auxilium() then
		return done(false, "an auxilium cannot call auxilia")
	end
	if not (caller and caller.legio) then
		return done(false, "only a miles in a legio can call in an auxilium")
	end
	if not (command.job and command.job:match("%S")) then
		return done(false, "an auxilium needs a job")
	end
	local id = self.runner:new_miles_id()
	local name = "auxilium " .. id:sub(1, 8)
	local prompt = Legio.auxilium_order(name, caller:display_name(), command.job)
	self.runner:start(StartMilesCommand.new({ cwd = caller.cwd, prompt = prompt, id = id, provider = MilesProcess.default_provider, model = Legio.model_for("auxilium"), mode = MilesProcess.default_mode }), function(ok)
		if ok then
			self.milites:update(id, function(m)
				m.caller = caller.id
				m.title = name
				m.due = self.clock() + Miles.auxilium_limit
			end)
		end
		self.log({ type = "legio", event = ok and "auxilium" or "auxilium_failed", from = caller.id, miles = id })
		done(ok, ok and name or "the auxilium didn't start")
	end)
end

function LegioProcess:lapse_auxilia()
	local now = self.clock()
	for _, m in ipairs(self.milites:all()) do
		if m:is_overdue(now) then
			self.milites:update_existing(m.id, function(a)
				a.due = nil
			end)
			local minutes = math.floor(Miles.auxilium_limit / 60)
			self.runner:stop(m.id, function(ok)
				self.log({ type = "legio", event = "auxilium_lapsed", from = m.id, to = m.caller, stopped = ok and true or false })
				if not self.milites:find(m.caller) then
					return
				end
				local outcome = ok and "and was stopped" or "and could not be stopped"
				local text = ("%s gave no report within %d minutes %s"):format(self:name_of(m.id), minutes, outcome)
				self:deliver({ { miles = m.caller, name = self:name_of(m.caller) } }, text)
			end, "auxilium_lapsed")
		end
	end
end

local function among(recipients, id)
	for _, r in ipairs(recipients) do
		if r.miles == id then
			return true
		end
	end
	return false
end

function LegioProcess:report(command)
	local sender = self:find_miles(command.from)
	if sender and sender.caller then
		return report_as_auxilium(self, sender, command)
	end
	if command.kind ~= nil and not ({ decision = true, blocker = true, done = true })[command.kind] then
		return nil, "kind must be decision, blocker or done"
	end
	local chain = self:chain_of(command.from)
	if not chain then
		return nil, "you hold no post in a legio"
	end
	local route = chain_of_command.report_route(chain, command.kind, self:centuria_of(command.from), function(id)
		return self:name_of(id)
	end)
	if not route.recipient then
		return nil, "you report to the commander: say it in your reply"
	end
	local text = chain_of_command.report(self:name_of(command.from), chain.post, command.text, Legio.command)
	self.log({ type = "legio", event = "report", from = command.from, to = route.recipient.miles, kind = command.kind })
	if #route.copy > 0 then
		self:deliver(route.copy, "Copy: " .. text)
	end
	return self:deliver({ route.recipient }, text)
end

function LegioProcess:order(command)
	local chain = self:chain_of(command.from)
	if not chain then
		return nil, "you hold no post in a legio"
	end
	local recipients = chain_of_command.pick(chain.subordinates, command.to)
	if #recipients == 0 then
		return nil, #chain.subordinates == 0 and "you command no one" or ("no %s under you"):format(command.to)
	end
	self.log({ type = "legio", event = "order", from = command.from, to = command.to })
	local centuria = chain.post == "centurio" and self:centuria_of(command.from) or nil
	if centuria then
		self.centuriae:update_existing(centuria.id, function(c)
			return c:record_decision(command.to, command.text, self.clock())
		end)
		if centuria.optio and not among(recipients, centuria.optio) then
			self:deliver({ { miles = centuria.optio, name = self:name_of(centuria.optio) } }, ("%s ordered %s: %s"):format(self:name_of(command.from), command.to, command.text))
		end
	end
	return self:deliver(recipients, chain_of_command.order(self:name_of(command.from), chain.post, command.text, Legio.command))
end

function LegioProcess:submit_plan(command)
	local contubernium = self.contubernia:of(command.from)
	local decanus = contubernium and contubernium:decanus()
	if not (decanus and decanus.miles == command.from) then
		return nil, "only a decanus submits a plan"
	end
	local centuria = contubernium.centuria and self.centuriae:get(contubernium.centuria)
	local approver = centuria and (centuria.optio or centuria.centurio)
	if not approver then
		return nil, "your centuria has no optio or centurio to approve the plan"
	end
	self.contubernia:update(contubernium.id, function(t)
		return t:submit_plan(command.text, self.clock())
	end)
	self.log({ type = "legio", event = "plan", from = command.from, contubernium = contubernium.id })
	local name = self:name_of(command.from)
	local others = {}
	for _, c in ipairs(self.contubernia:all()) do
		local d = c.centuria == contubernium.centuria and c.id ~= contubernium.id and c:decanus()
		if d then
			table.insert(others, { name = c.name, decanus = self:name_of(d.miles), plan = c.plan })
		end
	end
	local message = ("%s submitted a plan for approval:\n\n%s\n\nApprove it with `%s approve %s`."):format(name, command.text, Legio.command, name)
	local digest = Contubernium.plans_digest(others)
	if digest ~= "" then
		message = message .. "\n\nThe other contubernia in your centuria, as they stand:\n\n" .. digest
	end
	self:deliver({ { miles = approver, name = self:name_of(approver) } }, message)
	return true
end

function LegioProcess:align_plan(command)
	local centuria = self:centuria_of(command.from)
	local approver = centuria and (centuria.optio or centuria.centurio)
	if not (centuria and approver == command.from) then
		return nil, "only the optio (or the centurio when there is no optio) aligns plans"
	end
	local known = {}
	for _, c in ipairs(self.contubernia:all()) do
		local decanus = c.centuria == centuria.id and c:decanus()
		if decanus then
			known[self:name_of(decanus.miles)] = true
		end
	end
	local wanted, requested = {}, {}
	if command.to ~= "all" then
		for name in command.to:gmatch("[^,]+") do
			name = name:match("^%s*(.-)%s*$")
			if name ~= "" then
				if not known[name] then
					return nil, ("no decanus %s in your centuria"):format(name)
				end
				wanted[name] = true
				table.insert(requested, name)
			end
		end
		if #requested == 0 then
			return nil, "name at least one decanus, or all"
		end
	end
	local targets = {}
	for _, c in ipairs(self.contubernia:all()) do
		local decanus = c.centuria == centuria.id and c.plan and c:decanus()
		if decanus and (command.to == "all" or wanted[self:name_of(decanus.miles)]) then
			table.insert(targets, { contubernium = c, decanus = decanus, handed = c:handed_out() })
		end
	end
	if #targets == 0 then
		return nil, ("no decanus %s has a plan to align"):format(command.to)
	end
	local by, at = self:name_of(command.from), self.clock()
	for _, t in ipairs(targets) do
		self.contubernia:update(t.contubernium.id, function(c)
			return c:add_shared(command.text, by, at)
		end)
	end
	local names = {}
	for _, t in ipairs(targets) do
		local others = {}
		for _, o in ipairs(targets) do
			if o ~= t then
				table.insert(others, self:name_of(o.decanus.miles))
			end
		end
		local with = #others > 0 and (" and " .. table.concat(others, ", ")) or ""
		local text = ("%s agreed this shared part with you%s: %s"):format(by, with, command.text)
		for _, n in ipairs(self:deliver({ { miles = t.decanus.miles, name = self:name_of(t.decanus.miles) } }, text)) do
			table.insert(names, n)
		end
		if t.handed then
			local shared = Contubernium.shared_line(by, command.text)
			for _, m in ipairs(t.contubernium.members) do
				if m.miles ~= t.decanus.miles then
					self:deliver({ { miles = m.miles, name = self:name_of(m.miles) } }, shared)
				end
			end
		end
	end
	local planned, skipped = {}, {}
	for _, t in ipairs(targets) do
		planned[self:name_of(t.decanus.miles)] = true
	end
	for _, name in ipairs(requested) do
		if not planned[name] then
			table.insert(skipped, name)
		end
	end
	self.log({ type = "legio", event = "align", from = command.from, decani = #targets })
	return names, #skipped > 0 and skipped or nil
end

function LegioProcess:hand_out_plan(command)
	local contubernium = self.contubernia:of(command.from)
	local decanus = contubernium and contubernium:decanus()
	if not (decanus and decanus.miles == command.from) then
		return nil, "only a decanus hands a plan out"
	end
	if not contubernium:plan_approved() then
		return nil, "your plan is not approved yet"
	end
	if contubernium:handed_out() then
		return nil, "already handed out; resubmit the plan to change it"
	end
	self.contubernia:update(contubernium.id, function(t)
		return t:mark_handed_out(self.clock())
	end)
	local names = {}
	for _, m in ipairs(contubernium.members) do
		if m.miles ~= command.from then
			for _, n in ipairs(self:deliver({ { miles = m.miles, name = self:name_of(m.miles) } }, contubernium:plan_for(m.role))) do
				table.insert(names, n)
			end
		end
	end
	self.log({ type = "legio", event = "handout", from = command.from, contubernium = contubernium.id, size = #names })
	return names
end

function LegioProcess:approve_plan(command)
	local centuria = self:centuria_of(command.from)
	local approver = centuria and (centuria.optio or centuria.centurio)
	if not (centuria and approver == command.from) then
		return nil, "only the optio (or the centurio when there is no optio) approves a plan"
	end
	local contubernium
	for _, c in ipairs(self.contubernia:all()) do
		local decanus = c.centuria == centuria.id and c:decanus()
		if decanus and decanus.name == command.name then
			contubernium = c
		end
	end
	if not contubernium then
		return nil, ("no contubernium under you has the decanus %s"):format(command.name)
	end
	if not contubernium.plan then
		return nil, command.name .. " has submitted no plan"
	end
	local decanus = contubernium:decanus()
	self.contubernia:update(contubernium.id, function(t)
		return t:approve_plan(self:name_of(command.from), self.clock())
	end)
	self.log({ type = "legio", event = "approve", from = command.from, contubernium = contubernium.id })
	self:deliver({ { miles = decanus.miles, name = decanus.name } }, ("Your plan is approved by %s. Your faber may edit files now."):format(self:name_of(command.from)))
	return true
end

function LegioProcess:set_commander_commits(from, root, on)
	local miles = from and self:find_miles(from)
	if miles and miles.legio then
		return nil, "an enlisted miles can't set this: only the commander does"
	end
	local key = Cohors.key(root)
	if not self.cohortes:get(key) then
		return nil, "no cohors for this codebase"
	end
	self.cohortes:update_existing(key, function(c)
		c.commander_commits = on == true
	end)
	return true
end

function LegioProcess:status(from)
	local chain = self:chain_of(from)
	if not chain then
		return nil, "you hold no post in a legio"
	end
	local now = self.clock()
	local deployed = PostResolver.deployed({ legiones = self.legio_repository, centuriae = self.centuriae, cohortes = self.cohortes, contubernia_records = self.contubernia })
	local out = {}
	local tree = chain_of_command.below(chain, self.contubernia:all(), function(id)
		return self:centuria_of(id)
	end)
	local function walk(nodes, depth)
		for _, node in ipairs(nodes) do
			local miles = self.milites:find(node.miles)
			if miles then
				local _, post = PostResolver.of(node.miles, deployed, miles)
				table.insert(out, mapper.to_miles_status_dto(node.name, post or miles.role or "miles", miles:pulse(now), depth))
			end
			walk(node.children, depth + 1)
		end
	end
	walk(tree, 0)
	return out
end

function LegioProcess:record_account(command)
	local centuria = self:centuria_of(command.from)
	if not (centuria and centuria.centurio == command.from) then
		return nil, "only the centurio writes the account of an expeditio"
	end
	local legio = self.legio_repository:get(centuria.legio)
	if not (legio and legio.centuria == centuria.id) then
		return nil, "your legio is not on this expeditio any more"
	end
	local written = false
	self.centuriae:update_existing(centuria.id, function(c)
		written = c:write_account(command.text, command.from)
		return written
	end)
	if not written then
		return nil, "your centuria is gone"
	end
	self.log({ type = "legio", event = "account", centuria = centuria.id, from = command.from })
	return true
end

function LegioProcess:record_lesson(command)
	local miles = self.milites:find(command.from)
	if not (miles and self:centuria_of(command.from) and self.legio_repository:get(miles.legio)) then
		return nil, "you hold no post in a legio"
	end
	local learned = false
	self.legio_repository:update_existing(miles.legio, function(l)
		learned = l:learn(command.text)
		return learned
	end)
	self.log({ type = "legio", event = "lesson", legio = miles.legio, from = command.from })
	return true, learned
end

function LegioProcess:running_legio(expeditio_id)
	for _, legio in ipairs(self.legio_repository:all()) do
		if legio:is_deployed() and legio.expeditio == expeditio_id then
			return legio
		end
	end
end

local function state_of(expeditio, id)
	for _, m in ipairs(expeditio.mandata) do
		if m.id == id then
			return m.state
		end
	end
end

function LegioProcess:idle_contubernium(centuria, expeditio)
	for _, c in ipairs(self:contubernia_of(centuria)) do
		if c and c:is_idle(state_of(expeditio, c.todo)) then
			return c
		end
	end
end

function LegioProcess:hand_out(contubernium, mandatum, earlier_state)
	local decanus = contubernium:decanus()
	if not self.todos.assign(mandatum.id, decanus.miles) then
		return false
	end
	self.contubernia:update(contubernium.id, function(c)
		c:take(mandatum.id)
	end)
	self.todos.send(mandatum.id, decanus.miles, decanus.miles)
	local intro = earlier_state == "done" and "Your contubernium's last mandatum is finished, so a new one is yours."
		or "Your contubernium is standing by, so a new mandatum is yours as well. The one you had before stays yours: you still mark it done when it is finished."
	local order = ("%s\n\n%s\n\nOnce it is finished, mark it done: `%s done %s \"<what the contubernium did>\"`."):format(intro, mandatum.text, self.todos.done_command, mandatum.id)
	self.runner:hold_text(decanus.miles, order)
	self.log({ type = "legio", event = "mandatum_taken", mandatum = mandatum.id, contubernium = contubernium.id, miles = decanus.miles })
	return true
end

function LegioProcess:tell_centurio(centuria, text)
	if centuria.centurio then
		self.runner:hold_text(centuria.centurio, text)
	end
end

function LegioProcess:drop_waiting(centuria_id, mandatum_id)
	self.centuriae:update_existing(centuria_id, function(c)
		c:stop_waiting(mandatum_id)
	end)
end

function LegioProcess:closed_or_moved(centuria, mandatum_id)
	local expeditio = self.expeditiones.of(mandatum_id)
	if not (expeditio and expeditio.id == centuria.expeditio) then
		return true
	end
	for _, m in ipairs(expeditio.mandata) do
		if m.id == mandatum_id then
			return m.state ~= "open"
		end
	end
	return true
end

function LegioProcess:offer_mandatum(mandatum_id)
	local expeditio = self.expeditiones.of(mandatum_id)
	local legio = expeditio and self:running_legio(expeditio.id)
	local centuria = legio and legio.centuria and self.centuriae:get(legio.centuria)
	if not centuria then
		return nil
	end
	local mandatum
	for _, m in ipairs(expeditio.mandata) do
		if m.id == mandatum_id then
			mandatum = m
		end
	end
	if not mandatum or mandatum.state ~= "open" then
		self:drop_waiting(centuria.id, mandatum_id)
		return nil
	end
	if mandatum.assignee or Contubernium.for_todo(self.contubernia:all(), mandatum_id) then
		return nil
	end
	local idle = self:idle_contubernium(centuria, expeditio)
	if idle and self:hand_out(idle, mandatum, state_of(expeditio, idle.todo)) then
		self.centuriae:update_existing(centuria.id, function(c)
			c:stop_waiting(mandatum_id)
		end)
		return { taken = true, contubernium = idle.id }
	end
	self.centuriae:update_existing(centuria.id, function(c)
		c:wait_for_contubernium(mandatum_id)
	end)
	self:tell_centurio(centuria, ("A new mandatum, %s (%s), waits for a free contubernium: every contubernium of the centuria is busy."):format(mandatum.title, mandatum.id))
	return { waits = true }
end

function LegioProcess:decanus_contubernium(miles_id)
	local contubernium = self.contubernia:of(miles_id)
	if not contubernium then
		return nil, "you are not in a contubernium"
	end
	if contubernium:decanus().miles ~= miles_id then
		return nil, "only the decanus can do that for the contubernium"
	end
	return contubernium
end

function LegioProcess:stand_by(miles_id, mandatum_id)
	local contubernium, why = self:decanus_contubernium(miles_id)
	if not contubernium then
		return nil, why == "only the decanus can do that for the contubernium" and "only the decanus can stand the contubernium by" or why
	end
	local held = contubernium.todo
	local target = mandatum_id or held
	if target ~= held then
		if not held then
			return nil, "your contubernium holds no mandatum"
		end
		return nil, ("your contubernium still holds %s, so it can't be ready for %s"):format(held, tostring(target))
	end
	self.contubernia:update(contubernium.id, function(c)
		return c:stand_by(self.clock())
	end)
	local centuria = contubernium.centuria and self.centuriae:get(contubernium.centuria)
	for _, id in ipairs(centuria and { unpack(centuria.waiting) } or {}) do
		if self:closed_or_moved(centuria, id) then
			self:drop_waiting(centuria.id, id)
		else
			self:offer_mandatum(id)
		end
	end
	return true
end

function LegioProcess:take_mandatum(miles_id, mandatum_id)
	local contubernium, why = self:decanus_contubernium(miles_id)
	if not contubernium then
		return nil, why
	end
	local expeditio = self.expeditiones.of(mandatum_id)
	local ours = expeditio and contubernium.centuria and self.centuriae:get(contubernium.centuria)
	if not (ours and ours.expeditio == expeditio.id) then
		return nil, tostring(mandatum_id) .. " is no mandatum of your expeditio"
	end
	if state_of(expeditio, mandatum_id) ~= "open" and not contubernium:held(mandatum_id) then
		return nil, mandatum_id .. " is not open"
	end
	local holder = Contubernium.for_todo(self.contubernia:all(), mandatum_id)
	if holder and holder.id ~= contubernium.id then
		return nil, mandatum_id .. " is held by " .. holder:label()
	end
	self.contubernia:update(contubernium.id, function(c)
		if not c:held(mandatum_id) then
			c:take(mandatum_id)
		end
		c.todo, c.stood_by = mandatum_id, nil
	end)
	local centuria = contubernium.centuria and self.centuriae:get(contubernium.centuria)
	if centuria then
		self.centuriae:update_existing(centuria.id, function(c)
			c:stop_waiting(mandatum_id)
		end)
	end
	return true
end

function LegioProcess:withdraw(legio, plan)
	for _, s in ipairs(plan.squads) do
		self.contubernia:remove(s.contubernium.id)
	end
	self.centuriae:remove(plan.centuria.id)
	self.cohortes:update_existing(plan.centuria.cohors, function(c)
		c:leave(plan.centuria.id)
		if plan.primus_pilus and c.primus_pilus == plan.primus_pilus.id then
			c.primus_pilus = nil
		end
		return #c.centuriae == 0 and "delete" or true
	end)
	self.legio_repository:update_existing(legio.id, function(l)
		l.expeditio, l.centuria = nil, nil
	end)
end

return M
