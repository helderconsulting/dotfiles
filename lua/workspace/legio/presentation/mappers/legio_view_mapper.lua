local LegioPickViewModel = require("workspace.legio.presentation.view_models.legio_pick_view_model")
local LegioEntryViewModel = require("workspace.legio.presentation.view_models.legio_entry_view_model")
local LegionLineViewModel = require("workspace.legio.presentation.view_models.legion_line_view_model")
local LegionThreadViewModel = require("workspace.legio.presentation.view_models.legion_thread_view_model")
local rank_view_mapper = require("workspace.legio.presentation.mappers.rank_view_mapper")
local miles_cards = require("workspace.legio.presentation.mappers.miles_view_mapper")
local MeterViewModel = require("workspace.legio.presentation.view_models.meter_view_model")

local M = {}

local step = "  "

local tones = { starting = "busy" }

local function row(...)
	return { segments = { ... } }
end

local function who(post)
	if not post then
		return "none yet"
	end
	return post.standing and (post.name .. " " .. rank_view_mapper.insignia(post.standing.level)) or post.name
end

local function post_line(post, depth)
	return LegionLineViewModel.new({
		id = "post:" .. (post.miles_id or post.name),
		name = post.name,
		depth = depth,
		kind = post.tone or tones[post.state] or "off",
		miles_id = post.miles_id,
		indent = step:rep(depth),
		bar = "▏",
		card = {
			post.name .. (post.standing and (" " .. rank_view_mapper.to_rank_label(post.standing)) or ""),
			post.post,
			post.state or "starting",
		},
	})
end

local leaders = {
	cohors = { "primus pilus" },
	centuria = { "centurio", "optio" },
	contubernium = { "decanus" },
}

local function leader_row(mark, title, post)
	return row({ mark .. " " .. title .. " " .. who(post), post and "busy" or "off" })
end

local function strength(unit)
	local size = #(unit.milites or {})
	for _, child in ipairs(unit.units or {}) do
		size = size + strength(child) + (child.leader and 1 or 0) + (child.second and 1 or 0)
	end
	return size
end

local function unit_line(unit, depth)
	local titles = leaders[unit.kind] or {}
	local size = strength(unit)
	return LegionLineViewModel.new({
		id = unit.kind .. ":" .. unit.id,
		name = unit.label,
		depth = depth,
		kind = unit.leader and unit.leader.tone or "off",
		indent = step:rep(depth),
		bar = "▎",
		card = {
			leader_row("★", titles[1], unit.leader),
			row({ unit.kind, "ok" }, { " · " .. unit.label .. " · " .. size .. (size == 1 and " miles" or " milites"), "off" }),
			titles[2] and leader_row("☆", titles[2], unit.second) or "",
		},
	})
end

local function add_unit(lines, unit, depth)
	table.insert(lines, unit_line(unit, depth))
	for _, post in ipairs(unit.milites or {}) do
		table.insert(lines, post_line(post, depth + 1))
	end
	for _, child in ipairs(unit.units or {}) do
		add_unit(lines, child, depth + 1)
	end
end

function M.to_legion_thread(legio)
	local lines = {}
	if legio.cohors then
		table.insert(lines, LegionLineViewModel.new({ id = "ranks", depth = 0, kind = "off", card = { "ranks", rank_view_mapper.to_rank_legend(legio.ranks), "" } }))
		add_unit(lines, legio.cohors, 0)
	end
	return LegionThreadViewModel.new({ items = lines, unread = 0 })
end

local function hierarchy_row(post, place, role, mark, leader)
	return {
		id = post.miles_id or post.name,
		miles_id = post.miles_id,
		name = post.name,
		mark = mark,
		leader = leader,
		place = place,
		role = role,
		word = post.state or "starting",
		standing = post.standing,
	}
end

function M.deployed_miles_ids(legiones)
	local ids = {}
	local function collect(unit)
		for _, post in ipairs(unit.milites or {}) do
			if post.miles_id then
				ids[post.miles_id] = true
			end
		end
		if unit.leader and unit.leader.miles_id then
			ids[unit.leader.miles_id] = true
		end
		if unit.second and unit.second.miles_id then
			ids[unit.second.miles_id] = true
		end
		for _, child in ipairs(unit.units or {}) do
			collect(child)
		end
	end
	for _, legio in ipairs(legiones) do
		if legio.deployed and legio.cohors then
			collect(legio.cohors)
		end
	end
	return ids
end

local function miles_row(post, dto_of, group, role, mark, leader, label, position)
	local dto = dto_of(post)
	if dto then
		return miles_cards.to_miles_row(dto, dto.name, label, position)
	end
	return hierarchy_row(post, group, role, mark, leader)
end

local state_rank = { working = 1, starting = 2, waiting = 3, limited = 4, handing_over = 5, idle = 6, done = 7 }

local function state_line(posts)
	local counts, order = {}, {}
	for _, post in ipairs(posts) do
		local state = post.state or "starting"
		if not counts[state] then
			counts[state] = 0
			table.insert(order, state)
		end
		counts[state] = counts[state] + 1
	end
	table.sort(order, function(a, b)
		return (state_rank[a] or 99) < (state_rank[b] or 99)
	end)
	local parts = {}
	for _, state in ipairs(order) do
		table.insert(parts, counts[state] .. " " .. state)
	end
	return #parts > 0 and table.concat(parts, " · ") or "no milites"
end

local function members_below(unit)
	local posts = {}
	if unit.second then
		table.insert(posts, unit.second)
	end
	for _, post in ipairs(unit.milites or {}) do
		table.insert(posts, post)
	end
	for _, child in ipairs(unit.units or {}) do
		if child.leader then
			table.insert(posts, child.leader)
		end
		for _, post in ipairs(members_below(child)) do
			table.insert(posts, post)
		end
	end
	return posts
end

local function short_name(name)
	return (name or ""):match("^(.-) · ") or name
end

local function kind_label(unit)
	local label = unit.label or ""
	if label:sub(1, #unit.kind) == unit.kind then
		return label
	end
	return unit.kind .. " " .. label
end

local function name_of_unit(unit)
	local label = unit.label or ""
	return label:match("^" .. unit.kind .. " (.+)$") or (label ~= "" and label) or unit.id or unit.kind
end

local function unit_title(unit, role, leader_name)
	local parts = {}
	for _, part in ipairs({ name_of_unit(unit), leader_name or "", role }) do
		if part ~= "" then
			table.insert(parts, part)
		end
	end
	return table.concat(parts, " · ")
end

local function member_line(post, dto, glyph, name)
	local context = dto and dto.context_fraction and ("%d%%"):format(math.floor(dto.context_fraction * 100 + 0.5)) or "–"
	local model = dto and dto.model_label or "–"
	local role = post.post or (dto and dto.role) or ""
	return glyph .. " " .. name .. " " .. role .. " · " .. (post.state or "starting") .. " · " .. context .. " · " .. model
end

local function review_counts(line)
	local out = {}
	for part in (line or ""):gmatch("[^·]+") do
		local word = part:match("^%s*%d+ (%a+)%s*$")
		if word == "open" or word == "resolved" then
			table.insert(out, (part:gsub("^%s+", ""):gsub("%s+$", "")))
		end
	end
	return out
end

function M.unit_card(lines, summary)
	local out = { summary.title }
	if summary.task then
		table.insert(out, summary.task)
	end
	local word = summary.word
	for _, count in ipairs(review_counts(lines[3])) do
		word = word .. " · " .. count
	end
	table.insert(out, word)
	local last = #lines
	if last > 3 and MeterViewModel.is(lines[last]) then
		table.insert(out, lines[last])
		last = last - 1
	end
	for i = 4, last do
		table.insert(out, lines[i])
	end
	return out
end

function M.to_hierarchy_entries(legio, order, dto_of, mandatum_of, names_of)
	dto_of = dto_of or function(post)
		return post
	end
	mandatum_of = type(mandatum_of) == "function" and mandatum_of or function()
		return nil
	end
	names_of = type(names_of) == "function" and names_of or function()
		return nil
	end
	local function own_name(post)
		local dto = dto_of(post)
		return short_name(post.name) or (dto and short_name(dto.name)) or names_of(post.miles_id) or post.name
	end
	local out = {}
	local contubernia_seen = false
	local function push(fields)
		table.insert(out, LegionLineViewModel.new({
			id = "legio:" .. legio.id .. "/" .. fields.id,
			name = fields.name,
			order = order + (#out + 1) / 1000,
			depth = fields.depth,
			kind = fields.kind,
			card = fields.card,
			miles_id = fields.miles_id,
			label = fields.label,
			position = fields.position,
			live = fields.live,
			summary = fields.summary,
			indent = "",
			bar = "▎",
		}))
	end
	local function push_row(row, name, kind, depth, label, position, summary, live)
		local card = miles_cards.to_card_lines(row)
		if summary then
			card = M.unit_card(card, summary)
		end
		push({ id = row.id, name = name, kind = kind, depth = depth, card = card, miles_id = row.miles_id, label = label, position = position, summary = summary, live = live })
	end
	local function compact(post, depth, glyph)
		push({ id = "compact:" .. (post.miles_id or post.name), name = post.name, kind = post.tone or tones[post.state] or "off", depth = depth, card = { member_line(post, dto_of(post), glyph, own_name(post)) }, miles_id = post.miles_id })
	end
	local walk
	local function walk_cohors(unit, depth)
		local titles = leaders[unit.kind] or {}
		local group = unit.kind .. " " .. unit.label
		local size = strength(unit)
		push({ id = unit.kind .. ":" .. unit.id, name = unit.label, depth = depth, kind = "off", card = { { segments = { { unit.label, "lead" } } }, unit.kind .. " · " .. size .. (size == 1 and " miles" or " milites") } })
		if unit.leader then
			push_row(miles_row(unit.leader, dto_of, group, titles[1], "★ ", true, nil, 1), unit.leader.name, unit.leader.tone or "off", depth, nil, 1)
		end
		if unit.second then
			push_row(miles_row(unit.second, dto_of, group, titles[2], "☆ ", true, nil, nil), unit.second.name, unit.second.tone or "off", depth, nil, nil)
		end
		local base = unit.leader and 1 or 0
		for i, post in ipairs(unit.milites or {}) do
			push_row(miles_row(post, dto_of, group, post.post, "", nil, nil, i + base), post.name, post.tone or tones[post.state] or "off", depth + 1, nil, i + base)
		end
		for _, child in ipairs(unit.units or {}) do
			walk(child, depth + 1)
		end
	end
	local function walk_centuria(unit, depth)
		local group = kind_label(unit)
		if unit.leader then
			local summary = { title = unit_title(unit, "centurio", own_name(unit.leader)), word = state_line(members_below(unit)) }
			push_row(miles_row(unit.leader, dto_of, group, "centurio", "★ ", true, nil, 1), unit.leader.name, unit.leader.tone or "off", depth, nil, 1, summary, true)
		end
		local members = {}
		if unit.second then
			table.insert(members, unit.second)
		end
		for _, post in ipairs(unit.milites or {}) do
			table.insert(members, post)
		end
		for i, post in ipairs(members) do
			compact(post, depth + 1, i == #members and "└" or "├")
		end
		for _, child in ipairs(unit.units or {}) do
			walk(child, depth + 1)
		end
	end
	local function walk_contubernium(unit, depth)
		local members = unit.milites or {}
		if unit.leader then
			local summary = { title = unit_title(unit, "decanus", own_name(unit.leader)), task = mandatum_of(unit), word = state_line(members) }
			push_row(miles_row(unit.leader, dto_of, kind_label(unit), "decanus", "★ ", true, unit.label, 1), unit.leader.name, unit.leader.tone or "off", depth, unit.label, 1, summary, true)
		else
			push({ id = unit.kind .. ":" .. unit.id, name = name_of_unit(unit), kind = "off", depth = depth, card = { name_of_unit(unit), state_line(members) } })
		end
		out[#out].space_before = contubernia_seen or nil
		contubernia_seen = true
		for i, post in ipairs(members) do
			compact(post, depth + 1, i == #members and "└" or "├")
		end
	end
	walk = function(unit, depth)
		if unit.kind == "centuria" then
			return walk_centuria(unit, depth)
		elseif unit.kind == "contubernium" then
			return walk_contubernium(unit, depth)
		end
		return walk_cohors(unit, depth)
	end
	if legio.cohors then
		walk(legio.cohors, 0)
	end
	return out
end

local function deployment(legio)
	if legio.deployed and legio.expeditio then
		return "deployed on " .. legio.expeditio
	end
	return "in reserve"
end

local function full_name(legio)
	return legio.cognomen and (legio.name .. " " .. legio.cognomen) or legio.name
end

function M.to_legio_entry(legio, order)
	return LegioEntryViewModel.new({
		id = "legio:" .. legio.id,
		legio_id = legio.id,
		name = legio.name,
		kind = legio.deployed and "busy" or "off",
		order = order,
		deployed = legio.deployed,
		card = {
			full_name(legio),
			legio.munus .. " · " .. table.concat(legio.roles or {}, ", "),
			deployment(legio),
		},
	})
end

function M.to_legio_entries(legiones)
	local out = {}
	for i, legio in ipairs(legiones) do
		out[i] = M.to_legio_entry(legio, 200 + i)
	end
	return out
end

function M.to_deploy_picks(legiones)
	local out = {}
	for i, legio in ipairs(legiones) do
		out[i] = LegioPickViewModel.new({
			legio_id = legio.id,
			name = full_name(legio),
			tag = legio.deployed and "on campaign" or "in reserve",
			value = full_name(legio),
			description = legio.deployed and (legio.munus .. " · on " .. (legio.expeditio or "a campaign")) or legio.munus,
			deployed = legio.deployed,
			expeditio = legio.expeditio,
		})
	end
	return out
end

return M
