local M = {}

M.components = { require("configs.agents"), require("configs.epics") }
M.empty = "no active sessions or epics"

local function component(e)
	return e and e.component or M.components[1]
end

function M.fetch(folder, done)
	local lists, pending = {}, #M.components
	for i, c in ipairs(M.components) do
		c.fetch(folder, function(list)
			lists[i] = list
			pending = pending - 1
			if pending > 0 then
				return
			end
			local all = {}
			for k = 1, #M.components do
				for j, e in ipairs(lists[k] or {}) do
					e.space_before = k > 1 and j == 1 and #all > 0 or nil
					e.order = (k * 1000) + (e.order or 0)
					table.insert(all, e)
				end
			end
			done(all)
		end)
	end
end

function M.count(list)
	return #vim.tbl_filter(function(e)
		return e.component == M.components[1]
	end, list)
end

function M.card(e)
	return component(e).card(e)
end

function M.thread(e, ctx)
	return component(e).thread(e, ctx)
end

function M.follow(e, item)
	return component(e).follow(e, item)
end

function M.enter(e, view)
	return component(e).enter(e, view)
end

function M.escape(e, item)
	return component(e).escape(e, item)
end

local function guarded(owner, a)
	local fn = a[2]
	return function(e, ui, item)
		if not a.always and e and e.component ~= owner then
			if not ui.batch then
				vim.notify(("that's %s %s, not %s %s"):format(e.component.name == "epic" and "an" or "a", e.component.name, owner.name == "epic" and "an" or "a", owner.name), vim.log.levels.WARN)
			end
			return
		end
		return fn(e, ui, item)
	end
end

M.groups, M.actions = {}, {}
for _, c in ipairs(M.components) do
	vim.list_extend(M.groups, c.groups or {})
	for _, a in ipairs(c.actions or {}) do
		local wrapped = vim.deepcopy(a, true)
		wrapped[2] = guarded(c, a)
		table.insert(M.actions, wrapped)
	end
end

return M
