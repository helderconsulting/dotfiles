local M = {}

local function person(id, name)
	return id and { miles = id, name = name } or nil
end

local function decani(contubernia, name_of)
	local out = {}
	for _, c in ipairs(contubernia) do
		local d = c:decanus()
		if d then
			table.insert(out, person(d.miles, d.name or name_of(d.miles)))
		end
	end
	return out
end

local function others(c, id)
	local out = {}
	for _, m in ipairs(c.members) do
		if m.miles ~= id then
			table.insert(out, person(m.miles, m.name))
		end
	end
	return out
end

function M.of(id, centuria, contubernia, name_of, leader)
	local centurio = person(centuria.centurio, name_of(centuria.centurio))
	local optio = person(centuria.optio, name_of(centuria.optio))
	if centuria.centurio == id then
		local under = decani(contubernia, name_of)
		if optio then
			table.insert(under, 1, optio)
		end
		return { post = "centurio", superior = leader, subordinates = under }
	elseif centuria.optio == id then
		return { post = "optio", superior = centurio, subordinates = decani(contubernia, name_of) }
	end
	for _, c in ipairs(contubernia) do
		local d = c:decanus()
		if d and d.miles == id then
			return { post = "decanus", superior = optio or centurio, subordinates = others(c, id) }
		elseif c:has(id) then
			return { post = c:member_for(id).role, superior = person(d.miles, d.name), subordinates = {} }
		end
	end
end

function M.of_primus_pilus(centuriae, name_of)
	local under = {}
	for _, centuria in ipairs(centuriae) do
		if centuria.centurio then
			table.insert(under, person(centuria.centurio, name_of(centuria.centurio)))
		end
	end
	return { post = "primus pilus", subordinates = under }
end

function M.below(chain, contubernia, centuria_of)
	local function members_node(c, d)
		local node = { miles = d.miles, name = d.name, children = {} }
		for _, m in ipairs(c.members) do
			if m.miles ~= d.miles then
				table.insert(node.children, { miles = m.miles, name = m.name, children = {} })
			end
		end
		return node
	end
	local function decanus_node(c)
		local d = c:decanus()
		return d and members_node(c, d) or nil
	end
	local function contubernium_led_by(id)
		for _, c in ipairs(contubernia) do
			local d = c:decanus()
			if d and d.miles == id then
				return c
			end
		end
	end
	local out = {}
	if chain.post == "primus pilus" then
		for _, s in ipairs(chain.subordinates) do
			local node = { miles = s.miles, name = s.name, children = {} }
			local centuria = centuria_of and centuria_of(s.miles)
			for _, c in ipairs(contubernia) do
				local child = centuria and c.centuria == centuria.id and decanus_node(c)
				if child then
					table.insert(node.children, child)
				end
			end
			table.insert(out, node)
		end
	elseif chain.post == "centurio" or chain.post == "optio" then
		for _, s in ipairs(chain.subordinates) do
			local c = contubernium_led_by(s.miles)
			table.insert(out, c and decanus_node(c) or { miles = s.miles, name = s.name, children = {} })
		end
	else
		for _, s in ipairs(chain.subordinates) do
			table.insert(out, { miles = s.miles, name = s.name, children = {} })
		end
	end
	return out
end

function M.pick(subordinates, to)
	if to == "all" then
		return subordinates
	end
	for _, s in ipairs(subordinates) do
		if s.name == to then
			return { s }
		end
	end
	return {}
end

local ESCALATIONS = { decision = true, blocker = true, done = true }

function M.report_route(chain, kind, centuria, name_of)
	if chain.post == "decanus" and ESCALATIONS[kind] and centuria and centuria.centurio then
		local copy = {}
		if centuria.optio then
			table.insert(copy, person(centuria.optio, name_of(centuria.optio)))
		end
		return { recipient = person(centuria.centurio, name_of(centuria.centurio)), copy = copy }
	end
	return { recipient = chain.superior, copy = {} }
end

function M.report(name, post, text, command)
	return ("%s (%s) reports: %s\n\n(answer with `%s order %s \"<message>\"`)"):format(name, post, text, command, name)
end

function M.order(name, post, text, command)
	return ("Order from %s (%s): %s\n\n(report back with `%s report \"<message>\"`)"):format(name, post, text, command)
end

return M
