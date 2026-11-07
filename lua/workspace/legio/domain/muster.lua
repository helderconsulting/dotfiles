local unpack = table.unpack or unpack
local Legio = require("workspace.legio.domain.legio")
local Cohors = require("workspace.legio.domain.cohors")
local Centuria = require("workspace.legio.domain.centuria")
local Contubernium = require("workspace.legio.domain.contubernium")

local M = {}

local function size(legio, mandata)
	return 2 + #mandata * (1 + #legio.roles)
end

local function members_of(contubernium)
	local out = {}
	for _, m in ipairs(contubernium.members) do
		table.insert(out, m.role .. " " .. m.name)
	end
	return table.concat(out, ", ")
end

local function centuria_roster(centurio, optio, squads)
	local lines = { "centurio " .. centurio.name, "optio " .. optio.name }
	for _, s in ipairs(squads) do
		table.insert(lines, ("%s (%s): %s"):format(s.contubernium:label(), s.mandatum.title, members_of(s.contubernium)))
	end
	return table.concat(lines, "\n")
end

local function expeditio_brief(expeditio, squads)
	local lines = { "# " .. expeditio.title, "", "Its mandata, one contubernium each:", "" }
	for _, s in ipairs(squads) do
		table.insert(lines, ("- %s, held by %s under decanus %s"):format(s.mandatum.title, s.contubernium:label(), s.contubernium:decanus().name))
	end
	return table.concat(lines, "\n")
end

local function post(id, name, role, topic, prompt, mandatum, resumed)
	return { id = id, name = name, post = role, model = Legio.model_for(role), topic = topic, prompt = prompt, mandatum = mandatum, resume = resumed or nil }
end

local function decanus_workspace(commander_commits)
	if commander_commits then
		return "- Don't create a worktree and don't commit: the commander commits. Leave your changes in the checkout, and tell your milites the path to it."
	end
	return "- Create your worktree and branch. Tell your milites the path to your worktree. Commit, push and open the merge request yourself."
end

local function member_workspace(commander_commits)
	if commander_commits then
		return "- The commander commits: work in the checkout. Never create a worktree, commit or push."
	end
	return "- Work only in the decanus's worktree. Never create a worktree, commit or push."
end

local function squad_posts(legio, s, superior, done_command, commander_commits)
	local c, mandatum = s.contubernium, s.mandatum
	local decanus = c:decanus()
	local out = {
		post(decanus.miles, decanus.name, "decanus", mandatum.title, legio:orders({
			name = decanus.name,
			post = "decanus",
			mandatum = mandatum.text,
			unit = c:label(),
			roster = c:roster(),
			superior = superior.name,
			commands = true,
			extra = { decanus_workspace(commander_commits), ("- Once the mandatum is finished, mark it done: `%s done %s \"<what the contubernium did>\"`."):format(done_command, mandatum.id), ("- Decisions, blockers and the finished mandatum go to your centurio with `%s report --kind decision|blocker|done \"<message>\"`; your optio is copied. Routine reports go to your optio."):format(Legio.command), ("- After `%s done`, report it with `%s report --kind done \"<message>\"`."):format(done_command, Legio.command) },
		}), mandatum.id, decanus.resumed),
	}
	for _, m in ipairs(c.members) do
		if m ~= decanus then
			table.insert(out, post(m.miles, m.name, m.role, mandatum.title, legio:orders({
				name = m.name,
				post = m.role,
				mandatum = mandatum.text,
				unit = c:label(),
				roster = c:roster(),
				superior = decanus.name,
				extra = { member_workspace(commander_commits), ("- Only %s marks the mandatum done."):format(decanus.name) },
			})))
		end
	end
	return out
end

local function veteran_leaders(veterans, count)
	local triarii, principes = {}, {}
	for _, v in ipairs(veterans) do
		if v.rank == "triarius" then
			table.insert(triarii, v)
		elseif v.rank == "princeps" then
			table.insert(principes, v)
		end
	end
	local centurio, optio = table.remove(triarii, 1), table.remove(triarii, 1)
	local pool = principes
	for _, t in ipairs(triarii) do
		table.insert(pool, t)
	end
	local decani = {}
	for i = 1, count do
		decani[i] = table.remove(pool, 1)
	end
	return centurio, optio or table.remove(pool, 1), decani
end

function M.plan(legio, expeditio, o)
	local names = Legio.pick_names(o.taken_names or {}, size(legio, o.mandata) + (o.new_primus_pilus and 1 or 0))
	local used = 0
	local function next_name()
		used = used + 1
		return names[used]
	end
	local function member(veteran)
		if veteran then
			return { id = veteran.id, name = veteran.name, resumed = true }
		end
		return { id = o.new_id(), name = next_name() }
	end
	local centurio_veteran, optio_veteran, decani_veterans = veteran_leaders(o.veterans or {}, #o.mandata)
	local primus_pilus = o.new_primus_pilus and { id = o.new_id(), name = next_name() } or nil
	local centurio, optio = member(centurio_veteran), member(optio_veteran)
	local centuria = Centuria.make({
		id = o.centuria_id,
		legio = legio.id,
		cohors = Cohors.key(expeditio.root),
		expeditio = expeditio.id,
		title = expeditio.title,
		root = expeditio.root,
		centurio = centurio.id,
		optio = optio.id,
		created = o.at,
	})
	local known, squads = { unpack(o.contubernia or {}) }, {}
	for i, mandatum in ipairs(o.mandata) do
		local lead = member(decani_veterans[i])
		local members = { { name = lead.name, miles = lead.id, role = "decanus", resumed = lead.resumed } }
		for _, role in ipairs(legio.roles) do
			table.insert(members, { name = next_name(), miles = o.new_id(), role = role })
		end
		local c = Contubernium.enlist({
			id = o.new_contubernium_id(),
			name = Contubernium.pick_name(known, o.random),
			todo = mandatum.id,
			root = expeditio.root,
			base = o.base,
			members = members,
			created = o.at,
			centuria = centuria.id,
		})
		table.insert(known, c)
		table.insert(centuria.contubernia, c.id)
		table.insert(squads, { contubernium = c, mandatum = mandatum })
	end
	local decani = {}
	for _, s in ipairs(squads) do
		table.insert(decani, s.contubernium:decanus().name)
	end
	local roster, brief = centuria_roster(centurio, optio, squads), expeditio_brief(expeditio, squads)
	local unit = "Centuria " .. expeditio.title
	local posts = {
		post(centurio.id, centurio.name, "centurio", expeditio.title, legio:orders({ name = centurio.name, post = "centurio", expeditio = brief, unit = unit, roster = roster, superior = primus_pilus and primus_pilus.name, commands = true }), nil, centurio.resumed),
		post(optio.id, optio.name, "optio", expeditio.title, legio:orders({ name = optio.name, post = "optio", expeditio = brief, unit = unit, roster = roster, superior = centurio.name, commands = true }), nil, optio.resumed),
	}
	if primus_pilus then
		local cohors = Cohors.form(expeditio.root)
		table.insert(posts, 1, post(primus_pilus.id, primus_pilus.name, "primus pilus", cohors:label(), legio:orders({
			name = primus_pilus.name,
			post = "primus pilus",
			expeditio = brief,
			unit = cohors:label(),
			roster = "centurio " .. centurio.name .. " (" .. expeditio.title .. ")",
			commands = true,
		})))
	end
	for _, s in ipairs(squads) do
		for _, p in ipairs(squad_posts(legio, s, optio, o.done_command, o.commander_commits)) do
			table.insert(posts, p)
		end
	end
	return { centuria = centuria, squads = squads, posts = posts, primus_pilus = primus_pilus }
end

function M.title(p)
	return ("%s · %s · %s"):format(p.name, p.post, p.topic)
end

return M
