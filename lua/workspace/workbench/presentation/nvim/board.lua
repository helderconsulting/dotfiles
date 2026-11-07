local M = {}

local milites = require("workspace.legio.presentation.nvim.miles_panel")

M.components = {
	require("workspace.legio.presentation.nvim.legio_panel"),
	milites,
	require("workspace.workflow.presentation.nvim.expeditio_panel"),
}
M.empty = "no active sessions, expeditiones or legiones"

local articles = { expeditio = "an" }

local function named(c)
	return (articles[c.name] or "a") .. " " .. c.name
end

local function component(e)
	return e and e.component or milites
end

function M.entries_on_refresh(folder, done)
	local lists, pending = {}, #M.components
	for i, c in ipairs(M.components) do
		c.entries_on_refresh(folder, function(list)
			lists[i] = list
			pending = pending - 1
			if pending > 0 then
				return
			end
			local all = {}
			for k = 1, #M.components do
				for j, e in ipairs(lists[k] or {}) do
					e.space_before = e.space_before or k > 1 and j == 1 and #all > 0 or nil
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
		return e.component == milites
	end, list)
end

function M.card_on_render(e)
	return component(e).card_on_render(e)
end

local function resolve(e)
	if e and e.miles_id and e.component ~= milites then
		return milites.entry_for(e.miles_id, e.name) or e
	end
	return e
end

function M.thread_on_select(e, ctx)
	local target = resolve(e)
	local panel = target and target.component
	if panel and panel.thread_on_select then
		return panel.thread_on_select(target, ctx)
	end
	return nil
end

function M.show_conversation_on_select(e, item, opts)
	local target = resolve(e)
	return component(target).show_conversation_on_select(target, item, opts)
end

function M.open_on_enter(e, view)
	local target = resolve(e)
	return component(target).open_on_enter(target, view)
end

function M.handled_on_escape(e, item)
	local target = resolve(e)
	return component(target).handled_on_escape(target, item)
end

local function guarded(owner, a)
	local fn = a[2]
	return function(e, ui, item)
		e = resolve(e)
		if not a.always and e and e.component ~= owner then
			if not ui.batch then
				vim.notify(("that's %s, not %s"):format(named(e.component), named(owner)), vim.log.levels.WARN)
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
