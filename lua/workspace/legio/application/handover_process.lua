local StartMilesCommand = require("workspace.legio.application.commands.start_miles_command")
local Legio = require("workspace.legio.domain.legio")
local MilesProcess = require("workspace.legio.domain.miles_process")
local SetModelCommand = require("workspace.legio.application.commands.set_model_command")
local HandedOverDto = require("workspace.legio.application.dto.handed_over_dto")
local PostResolver = require("workspace.legio.domain.post_resolver")

local HandoverProcess = {}
HandoverProcess.__index = HandoverProcess

local M = {}

function M.new(ports)
	return setmetatable({
		milites = ports.milites,
		contubernia = ports.contubernia,
		centuriae = ports.centuriae,
		cohortes = ports.cohortes,
		legio_repository = ports.legiones,
		runner = ports.runner,
		todos = ports.todos,
		log = ports.log or function() end,
		clock = ports.clock or os.time,
	}, HandoverProcess)
end

function HandoverProcess:post_of(id)
	local deployed = PostResolver.deployed({
		legiones = self.legio_repository,
		centuriae = self.centuriae,
		cohortes = self.cohortes,
		contubernia_records = self.contubernia,
	})
	local _, post, source = PostResolver.of(id, deployed, self.milites:find(id))
	if post == "primus pilus" then
		return { cohors = source.cohors }
	elseif post == "centurio" or post == "optio" then
		return { centuria = source.centuria }
	elseif post then
		for _, contubernium in ipairs(source.contubernia) do
			if contubernium:member_for(id) then
				return { contubernium = contubernium }
			end
		end
	end
end

local function name_of(miles)
	return miles.roman_name or miles:display_name()
end

function HandoverProcess:check_stop(payload)
	if payload.continuing then
		return nil
	end
	local miles = self.milites:get(payload.session_id)
	if not (miles and miles:is_enlisted() and miles:due_for_handover() and self:post_of(miles.id)) then
		return nil
	end
	local fraction = miles:context_fraction()
	self.milites:update_existing(miles.id, function(m)
		return m:ask_for_traditio(self.clock())
	end)
	self.log({ type = "legio", event = "traditio asked", miles = miles.id, fraction = fraction })
	return { decision = "block", reason = Legio.traditio_order(name_of(miles), fraction) }
end

function HandoverProcess:seniority(id)
	local miles = self.milites:find(id)
	return miles and miles:seniority() or 0
end

function HandoverProcess:fall_in_contubernium(contubernium, fallen)
	local vacancy, after
	self.contubernia:update(contubernium.id, function(c)
		vacancy = c:fall(fallen.id, function(id)
			return self:seniority(id)
		end)
		after = c
		return vacancy ~= nil
	end)
	if not vacancy then
		return nil
	end
	local promoted = vacancy.promoted and vacancy.promoted.miles
	local cwd = fallen.cwd
	if promoted then
		local successor = self.milites:find(promoted)
		cwd = successor and successor.cwd or cwd
	end
	return {
		role = vacancy.role,
		promoted = promoted,
		promoted_to = "decanus",
		cwd = cwd,
		unit = after,
		mandatum = self.todos.text(after.todo),
		fill = function(name, id)
			self.contubernia:update(contubernium.id, function(c)
				c:fill(vacancy, name, id)
			end)
		end,
	}
end

function HandoverProcess:fall_in_centuria(centuria, fallen)
	local vacancy
	self.centuriae:update_existing(centuria.id, function(c)
		vacancy = c:fall(fallen.id)
		return vacancy ~= nil
	end)
	if not vacancy then
		return nil
	end
	local centurio_id = centuria.centurio
	if centuria.centurio == fallen.id then
		centurio_id = vacancy.promoted
	end
	local roster, subordinates = self:centuria_brief(centuria, centurio_id)
	return {
		role = vacancy.post,
		promoted = vacancy.promoted,
		promoted_to = "centurio",
		cwd = fallen.cwd,
		note = vacancy.promoted and self:handover_brief(centuria) or nil,
		brief = {
			unit = "Centuria " .. centuria.title,
			roster = roster,
			subordinates = subordinates,
			superior = vacancy.post == "optio" and self:leader_name(centurio_id) or nil,
		},
		fill = function(_, id)
			self.centuriae:update_existing(centuria.id, function(c)
				return c:fill(vacancy.post, id)
			end)
		end,
	}
end

function HandoverProcess:handover_brief(centuria)
	local lines = { "Where " .. centuria:label() .. " stands:" }
	for _, id in ipairs(centuria.contubernia or {}) do
		local contubernium = self.contubernia:get(id)
		if contubernium then
			table.insert(lines, "")
			table.insert(lines, contubernium:label() .. ", mandatum: " .. (self.todos.text(contubernium.todo) or ""))
			if contubernium.plan and contubernium.plan.text then
				table.insert(lines, "plan: " .. contubernium.plan.text)
			end
		end
	end
	if #centuria.decisions > 0 then
		table.insert(lines, "")
		table.insert(lines, "Decisions, most recent last:")
		for _, d in ipairs(centuria.decisions) do
			table.insert(lines, ("- to %s: %s"):format(d.to, d.text))
		end
	end
	return table.concat(lines, "\n")
end

function HandoverProcess:leader_name(id)
	local miles = id and self.milites:find(id)
	return miles and name_of(miles) or nil
end

function HandoverProcess:centuria_brief(centuria, centurio_id)
	local lines = {}
	local centurio = self:leader_name(centurio_id)
	if centurio then
		table.insert(lines, "centurio " .. centurio)
	end
	local decani = {}
	for _, id in ipairs(centuria.contubernia or {}) do
		local contubernium = self.contubernia:get(id)
		local decanus = contubernium and contubernium:decanus()
		if decanus then
			table.insert(decani, decanus.name)
			table.insert(lines, contubernium:label() .. ", decanus " .. decanus.name .. ":")
			table.insert(lines, contubernium:roster())
		end
	end
	return table.concat(lines, "\n"), decani
end

function HandoverProcess:deployed_centuriae()
	local out = {}
	for _, legio in ipairs(self.legio_repository:all()) do
		if legio:is_deployed() and legio.centuria then
			out[legio.centuria] = true
		end
	end
	return out
end

function HandoverProcess:most_senior_centurio(cohors)
	local best, best_rank
	local deployed = self:deployed_centuriae()
	for _, id in ipairs(cohors.centuriae) do
		local centuria = deployed[id] and self.centuriae:get(id)
		if centuria and centuria.centurio then
			local rank = self:seniority(centuria.centurio)
			if not best or rank > best_rank then
				best, best_rank = centuria, rank
			end
		end
	end
	return best
end

function HandoverProcess:fall_in_cohors(cohors, fallen)
	local successor = self:most_senior_centurio(cohors)
	if not successor then
		self.cohortes:update_existing(cohors.id, function(c)
			c.primus_pilus = nil
		end)
		return {
			role = "primus pilus",
			cwd = fallen.cwd,
			fill = function(_, id)
				self.cohortes:update_existing(cohors.id, function(c)
					return c:lead(id)
				end)
			end,
		}
	end
	local promoted, vacancy = successor.centurio
	self.cohortes:update_existing(cohors.id, function(c)
		c.primus_pilus = promoted
	end)
	self.centuriae:update_existing(successor.id, function(c)
		vacancy = c:fall(promoted)
		return vacancy ~= nil
	end)
	return {
		role = vacancy.post,
		promoted = promoted,
		promoted_to = "primus pilus",
		also = vacancy.promoted and { miles = vacancy.promoted, to = "centurio", note = self:handover_brief(successor) } or nil,
		superior = vacancy.promoted or promoted,
		cwd = fallen.cwd,
		fill = function(_, id)
			self.centuriae:update_existing(successor.id, function(c)
				return c:fill(vacancy.post, id)
			end)
		end,
	}
end

function HandoverProcess:taken_names(legio_id)
	local out = {}
	for _, m in ipairs(self.milites:plain_all()) do
		if m.legio == legio_id and m.roman_name then
			table.insert(out, m.roman_name)
		end
	end
	return out
end

function HandoverProcess:raise(id, post)
	local name
	self.milites:update_existing(id, function(m)
		m:promote(post)
		name = name_of(m)
	end)
	self.runner:set_model(SetModelCommand.new({ miles_id = id, model = Legio.model_for(post) }), function(ok)
		if not ok then
			self.log({ type = "legio", event = "model not switched", miles = id, post = post })
		end
	end)
	return name
end

function HandoverProcess:promote(vacancy, fallen_name, traditio)
	if not vacancy.promoted then
		return nil
	end
	local successor = self:raise(vacancy.promoted, vacancy.promoted_to)
	if vacancy.also then
		self:raise(vacancy.also.miles, vacancy.also.to)
		local also_note = ("%s has fallen, so you are %s now."):format(fallen_name, vacancy.also.to)
		if vacancy.also.note then
			also_note = also_note .. "\n\n" .. vacancy.also.note
		end
		self.runner:hold_text(vacancy.also.miles, also_note)
	end
	local note = ("%s has fallen, so you are %s now. This is the traditio he left:\n\n%s"):format(fallen_name, vacancy.promoted_to, traditio)
	if vacancy.note then
		note = note .. "\n\n" .. vacancy.note
	end
	self.runner:hold_text(vacancy.promoted, note)
	return successor
end

function HandoverProcess:orders(legio, vacancy, name)
	local o = { name = name, post = vacancy.role }
	if vacancy.unit then
		local decanus = vacancy.unit:decanus()
		o.mandatum = vacancy.mandatum
		o.unit = vacancy.unit:label()
		o.roster = vacancy.unit:roster()
		o.superior = decanus and decanus.name ~= name and decanus.name or nil
	end
	if vacancy.brief then
		o.unit, o.roster, o.commands = vacancy.brief.unit, vacancy.brief.roster, true
		o.superior = vacancy.brief.superior or o.superior
	end
	if vacancy.role == "decanus" then
		o.commands = true
	end
	if vacancy.role == "decanus" and vacancy.unit and vacancy.unit.centuria then
		local centuria = self.centuriae:get(vacancy.unit.centuria)
		o.superior = centuria and (self:leader_name(centuria.optio) or self:leader_name(centuria.centurio)) or o.superior
	end
	if vacancy.superior and not o.superior then
		local superior = self.milites:find(vacancy.superior)
		o.superior = superior and name_of(superior) or nil
	end
	return legio:orders(o)
end

function HandoverProcess:start_supplementum(legio, vacancy, fallen_name, traditio, done)
	local id = self.runner:new_miles_id()
	local name = Legio.pick_names(self:taken_names(legio.id), 1)[1]
	vacancy.fill(name, id)
	local prompt = Legio.supplementum_order(traditio, fallen_name, self:orders(legio, vacancy, name))
	local start = StartMilesCommand.new({ cwd = vacancy.cwd, prompt = prompt, id = id, provider = MilesProcess.default_provider, model = Legio.model_for(vacancy.role), mode = MilesProcess.default_mode })
	self.runner:start(start, function(ok)
		if ok then
			self.milites:update(id, function(m)
				m:enlist(legio.id, vacancy.role, name, vacancy.cwd)
				m.title = ("%s · %s"):format(name, vacancy.role)
			end)
		end
		done(ok, name)
	end)
end

function HandoverProcess:learn(legio_id, lesson)
	if not (lesson and lesson:match("%S")) then
		return
	end
	self.legio_repository:update_existing(legio_id, function(l)
		return l:learn(lesson)
	end)
	self.log({ type = "legio", event = "lesson", legio = legio_id, from = "traditio" })
end

function HandoverProcess:notify_superior(post, fallen_role, vacancy, fallen_name, name, successor)
	local superior
	if fallen_role == "decanus" and post.contubernium then
		local centuria = self.centuriae:get(post.contubernium.centuria)
		superior = centuria and (centuria.optio or centuria.centurio)
	elseif fallen_role == "optio" and post.centuria then
		superior = post.centuria.centurio
	elseif fallen_role == "centurio" and post.centuria and post.centuria.cohors then
		local cohors = self.cohortes:get(post.centuria.cohors)
		superior = cohors and cohors.primus_pilus
	elseif post.contubernium then
		local lead = post.contubernium:decanus()
		superior = lead and lead.miles
	end
	if superior then
		local text = successor and ("%s fell; %s became %s; %s took over as %s. Run legio status."):format(fallen_name, successor, vacancy.promoted_to, name, vacancy.role)
			or ("%s fell; %s took over as %s. Run legio status."):format(fallen_name, name, vacancy.role)
		self.runner:hold_text(superior, text)
	end
end

function HandoverProcess:hand_over(command, done)
	local fallen = self.milites:find(command.miles_id)
	local post = fallen and self:post_of(fallen.id)
	if not post then
		return done(false, "you hold no post in a legio")
	end
	self:learn(fallen.legio, command.lesson)
	local legio = self.legio_repository:get(fallen.legio)
	if not legio then
		return done(false, "your legio is gone")
	end
	local fallen_name = name_of(fallen)
	self.milites:update_existing(fallen.id, function(m)
		return m:fall(command.traditio, self.clock())
	end)
	local vacancy = post.contubernium and self:fall_in_contubernium(post.contubernium, fallen)
		or post.cohors and self:fall_in_cohors(post.cohors, fallen)
		or self:fall_in_centuria(post.centuria, fallen)
	local successor = self:promote(vacancy, fallen_name, command.traditio)
	self:start_supplementum(legio, vacancy, fallen_name, command.traditio, function(ok, name)
		local entry = successor and ("%s fell; %s is %s now, %s joined as %s"):format(fallen_name, successor, vacancy.promoted_to, name, vacancy.role)
			or ("%s fell; %s joined as %s"):format(fallen_name, name, vacancy.role)
		self.legio_repository:update_existing(legio.id, function(l)
			return l:record(ok and entry or (fallen_name .. " fell; no supplementum started"), self.clock())
		end)
		self.log({ type = "legio", event = "fell", legio = legio.id, miles = fallen.id, supplementum = ok and name or nil, promoted = vacancy.promoted })
			if ok then
				self:notify_superior(post, fallen.role, vacancy, fallen_name, name, successor)
			end
		self.runner:stop(fallen.id, function()
			done(true, HandedOverDto.new({ supplementum = ok and name or nil, successor = successor, role = vacancy.role }))
		end, "fell")
	end)
end

return M
