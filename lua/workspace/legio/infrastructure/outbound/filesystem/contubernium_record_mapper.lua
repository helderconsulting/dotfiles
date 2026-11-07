local Contubernium = require("workspace.legio.domain.contubernium")

local M = {}

local function members_to_domain(members)
	local out = {}
	for i, m in ipairs(members) do
		out[i] = { name = m.name, miles = m.agent, role = m.role }
	end
	return out
end

local function members_to_record(members)
	local out = {}
	for i, m in ipairs(members or {}) do
		out[i] = { name = m.name, agent = m.miles, role = m.role }
	end
	return out
end

function M.to_domain(record)
	return Contubernium:new({
		id = record.id,
		name = record.name,
		todo = record.todo,
		root = record.root,
		base = record.base,
		members = record.members and members_to_domain(record.members),
		created = record.created,
		centuria = record.centuria,
		stood_by = record.stood_by,
		earlier = record.earlier,
		plan = record.plan,
		plan_required = record.plan_required,
	})
end

function M.to_record(contubernium)
	return {
		id = contubernium.id,
		name = contubernium.name,
		todo = contubernium.todo,
		root = contubernium.root,
		base = contubernium.base,
		members = members_to_record(contubernium.members),
		created = contubernium.created,
		centuria = contubernium.centuria,
		stood_by = contubernium.stood_by,
		earlier = contubernium.earlier,
		plan = contubernium.plan,
		plan_required = contubernium.plan_required,
	}
end

return M
