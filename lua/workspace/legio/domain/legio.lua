local Model = require("workspace.shared.lib.model")
local Contubernium = require("workspace.legio.domain.contubernium")

local Legio = Model.extend({
	kind = "legiones",
	fields = { "id", "name", "munus", "roles", "annales", "mos_maiorum", "cognomen", "expeditiones", "expeditio", "centuria", "raised" },
})

Legio.command = "~/.config/wezterm/bin/legio"

Legio.standing = {
	{ id = "x-rapax", name = "Legio X Rapax", munus = "implement", roles = { "faber", "probator", "censor" } },
	{ id = "iv-obsidionalis", name = "Legio IV Obsidionalis", munus = "test and break", roles = { "probator", "censor" } },
	{ id = "ix-speculatrix", name = "Legio IX Speculatrix", munus = "explore", roles = { "explorator" } },
}

Legio.duties = {
	implement = "turning mandata into working code",
	["test and break"] = "checking that things work and trying to break them",
	explore = "using the computer and Chrome to test by hand, finding out and explaining how things work",
}

Legio.posts = {
	["primus pilus"] = { model = "opus", does = "You are the commander's second in command: you talk with the commander, the centuriones report to you, and you lead the centuriae of this cohors. Watch each one, answer them, keep their contubernia to their expeditiones, and report the cohors's progress to the commander." },
	centurio = { model = "opus", does = "You lead the centuria: you watch its contubernia, answer their decani, keep them to the expeditio and report its progress to the commander." },
	optio = { model = "opus", does = "You are the centurio's second: you keep the centuria aligned. You check each decanus's plan before work starts and approve it, settle file and function clashes between contubernia and tell both decani, and answer their routine reports yourself. You take over as centurio if he falls." },
	decanus = { model = "sonnet", does = "You lead the contubernium: you split the mandatum among its milites, keep each to his role, report to your superior, and mark the mandatum done once it's finished." },
	faber = { model = "haiku", does = "You write the code. You don't write the tests and you don't review." },
	probator = { model = "haiku", does = "You write and run the tests. You don't write the feature code and you don't review." },
	censor = { model = "haiku", does = "You review the code and the tests and say what's wrong. You don't change the code yourself." },
	explorator = { model = "haiku", does = "You scout: you use the computer and Chrome to try things by hand, find out how things work, and report back what you found. You don't change the code." },
	auxilium = { model = "haiku", does = "You are an auxilium: a helper for one narrow job. Do only that job, report the result with `legio report`, then stop. You earn no rank." },
}

Legio.honour = { cognomen = "Victrix", after = 3 }

Legio.praenomina = { "Gaius", "Marcus", "Lucius", "Titus", "Quintus", "Publius", "Gnaeus", "Sextus", "Aulus", "Decimus", "Servius", "Tiberius", "Spurius", "Manius", "Appius", "Numerius", "Kaeso", "Vibius" }

local function extend(list, more)
	for _, item in ipairs(more) do
		table.insert(list, item)
	end
	return list
end

local numerals = { "II", "III", "IV", "V", "VI", "VII", "VIII", "IX", "X" }

function Legio:init()
	self.roles = self.roles or {}
	self.annales = self.annales or {}
	self.mos_maiorum = self.mos_maiorum or {}
	self.expeditiones = self.expeditiones or 0
end

function Legio.raise(standing, at)
	return Legio:new({ id = standing.id, name = standing.name, munus = standing.munus, roles = standing.roles, raised = at })
end

function Legio.missing(legiones)
	local have = {}
	for _, l in ipairs(legiones) do
		have[l.id] = true
	end
	local out = {}
	for _, standing in ipairs(Legio.standing) do
		if not have[standing.id] then
			table.insert(out, standing)
		end
	end
	return out
end

function Legio.order(a, b)
	local rank = {}
	for i, s in ipairs(Legio.standing) do
		rank[s.id] = i
	end
	return (rank[a.id] or 99) < (rank[b.id] or 99)
end

function Legio.model_for(post)
	local p = Legio.posts[post]
	return p and p.model or Legio.posts.faber.model
end

function Legio.is_leader(post)
	return post == "primus pilus" or post == "centurio" or post == "optio" or post == "decanus"
end

function Legio:duty()
	return Legio.duties[self.munus] or self.munus
end

function Legio:is_deployed()
	return self.expeditio ~= nil
end

function Legio:can_deploy()
	if self:is_deployed() then
		return false, self.name .. " is already on an expeditio"
	end
	return true
end

function Legio:record(text, at)
	table.insert(self.annales, { at = at, text = text })
	return true
end

function Legio:learn(text)
	for _, custom in ipairs(self.mos_maiorum) do
		if (type(custom) == "table" and custom.text or custom) == text then
			return false
		end
	end
	table.insert(self.mos_maiorum, { text = text })
	return true
end

function Legio:deploy(expeditio, title, centuria, at)
	if self:is_deployed() then
		return false
	end
	self.expeditio, self.centuria = expeditio, centuria
	return self:record("deployed on " .. title, at)
end

function Legio:discharge(title, at)
	if not self:is_deployed() then
		return false
	end
	self.expeditio, self.centuria = nil, nil
	self.expeditiones = self.expeditiones + 1
	self:record("finished " .. title, at)
	if self:earns_cognomen() then
		self.cognomen = Legio.honour.cognomen
		self:record("earned the cognomen " .. self.cognomen, at)
	end
	return true
end

function Legio:earns_cognomen()
	return self.cognomen == nil and self.expeditiones >= Legio.honour.after
end

function Legio:has_role(role)
	for _, r in ipairs(self.roles) do
		if r == role then
			return true
		end
	end
	return false
end

function Legio.pick_names(taken, count)
	local used = {}
	for _, name in ipairs(taken) do
		used[name] = true
	end
	local out = {}
	local function try(name)
		if #out < count and not used[name] then
			used[name] = true
			table.insert(out, name)
		end
	end
	for _, name in ipairs(Legio.praenomina) do
		try(name)
	end
	for _, numeral in ipairs(numerals) do
		for _, name in ipairs(Legio.praenomina) do
			try(name .. " " .. numeral)
		end
	end
	return out
end

function Legio:customs()
	if #self.mos_maiorum == 0 then
		return nil
	end
	local lines = { "## Mos maiorum", "", "What " .. self.name .. " has learned so far:", "" }
	for _, custom in ipairs(self.mos_maiorum) do
		table.insert(lines, "- " .. (type(custom) == "table" and custom.text or tostring(custom)))
	end
	return table.concat(lines, "\n")
end

local function chain_of_command(o)
	local lines = {}
	if o.superior then
		table.insert(lines, ("- You report to %s with `%s report \"<message>\"`."):format(o.superior, Legio.command))
	else
		table.insert(lines, "- You report to the commander: say it in your replies.")
	end
	if o.commands then
		table.insert(lines, ("- To see who you command, run legio status; give them orders with `%s order <name|all> \"<message>\"`."):format(Legio.command))
	end
	table.insert(lines, "- A message reaches its receiver when their current turn ends.")
	return lines
end

function Legio:orders(o)
	local post = Legio.posts[o.post] or {}
	local lines = {
		("You are %s, %s of %s (%s: %s)."):format(o.name, o.post, self.name, self.munus, self:duty()),
		"",
		post.does or "",
		"Do only that. Leave the other roles to the milites who hold them.",
		"",
	}
	if o.mandatum then
		extend(lines, { "## Your mandatum", "", o.mandatum, "" })
	elseif o.expeditio then
		extend(lines, { "## The expeditio", "", o.expeditio, "" })
	end
	if o.roster then
		extend(lines, { "## " .. o.unit, "", o.roster, "" })
	end
	extend(lines, { "## Orders", "" })
	extend(lines, chain_of_command(o))
	table.insert(lines, ("- For a narrow job you can hand off: %s auxilium \"<job>\"; it reports back to you."):format(Legio.command))
	for _, extra in ipairs(o.extra or {}) do
		table.insert(lines, extra)
	end
	table.insert(lines, ("- When you learn something the whole legio should know from now on, record it with `%s lesson \"<lesson>\"`."):format(Legio.command))
	if o.post == "decanus" then
		table.insert(lines, ("- Once you have split the mandatum, write the contubernium's plan (who does what, which files) with `%s plan \"<text>\"`. Your optio (the centurio when there is none) approves it with `%s approve \"<decanus name>\"`, and you start work only after that. Keep sending routine reports to %s with `%s report \"<message>\"`."):format(Legio.command, Legio.command, o.superior or "your superior", Legio.command))
		table.insert(lines, ("- Once the mandatum is built and the censor has reviewed it, run `%s ready [<mandatum id>]`, naming the mandatum you finished (default: your current one). Only then does your contubernium count as idle and can take a new mandatum, even before you mark this one done. If you hold a newer mandatum, ready tells you which and does nothing. A mandatum someone gives you by hand is recorded with `%s take <mandatum id>`, otherwise it may be handed to another contubernium."):format(Contubernium.command, Contubernium.command))
		table.insert(lines, ("- After approval, hand the plan out with `%s handout`."):format(Legio.command))
	end
	if o.post == "optio" then
		table.insert(lines, "- You run the centuria day to day: routine reports, plan approvals and alignment come to you, and you are told every centurio decision. Keep track of open mandata, plans and decisions; you can take over as centurio at any moment.")
		table.insert(lines, ("- Forward to the centurio with `%s report` only approved plans, blockers, decisions and finished mandata. Answer routine reports from your decani yourself: acknowledged, stood by, function lists."):format(Legio.command))
		table.insert(lines, ("- Approve a decanus's plan with `%s approve \"<decanus name>\"` after reading it; the centurio approves when there is no optio."):format(Legio.command))
		table.insert(lines, ("- Align clashing plans with `%s align <decanus name|all> \"<shared part>\"`."):format(Legio.command))
	end
	if o.post == "centurio" then
		table.insert(lines, ("- You talk with the commander and decide. Your optio runs the centuria day to day; when you give a decision as an order, he is copied on it."))
		table.insert(lines, ("- Before the last mandatum is done, write the expeditio's account with `%s annales \"<account>\"`: it goes into the annales when the legio is discharged."):format(Legio.command))
	end
	table.insert(lines, ("- Your session is titled `%s · <what you work on>`. If you rename it with agent-title, keep your name in front."):format(o.name))
	table.insert(lines, ("- When your context gets nearly full you will be told to write a traditio with `%s traditio \"<handover>\"`; a supplementum then carries on your work."):format(Legio.command))
	local customs = self:customs()
	if customs then
		extend(lines, { "", customs })
	end
	return table.concat(lines, "\n")
end

function Legio.auxilium_order(name, caller, job)
	return table.concat({
		("You are %s, an auxilium called in by %s for one narrow job. You are not a miles of the legio: you hold no post and earn no rank."):format(name, caller),
		"",
		"## Your job",
		"",
		job,
		"",
		"## Orders",
		"",
		("- When your job is done, report the result to %s with `%s report \"<message>\"`. That report ends your session."):format(caller, Legio.command),
		"- Do only this job. Don't take on other work and don't mark any mandatum done.",
		"- Work in the folder you were started in.",
	}, "\n")
end

function Legio.traditio_order(name, fraction)
	return table.concat({
		("%s, your context is at %d%%. Before it runs out, hand over your post."):format(name, math.floor((fraction or 0) * 100 + 0.5)),
		"",
		("Write your traditio now with `%s traditio \"<handover>\"`. Put in it:"):format(Legio.command),
		"- your mandatum (or expeditio) and your role",
		"- your branch and worktree",
		"- what is done",
		"- what is left",
		"- what you were about to do next",
		"- anything you were waiting on, and from whom",
		("- a lesson for the whole legio, if you have one: add it as a second argument, `%s traditio \"<handover>\" \"<lesson>\"`"):format(Legio.command),
		"",
		"A supplementum takes over your post with it as his first order. Don't start new work after writing it.",
	}, "\n")
end

function Legio.supplementum_order(traditio, fallen, extra)
	local lines = {
		("You are a supplementum: you take over from %s, who has fallen. This is the traditio he left you:"):format(fallen),
		"",
		traditio,
	}
	if extra then
		extend(lines, { "", extra })
	end
	return table.concat(lines, "\n")
end

return Legio
