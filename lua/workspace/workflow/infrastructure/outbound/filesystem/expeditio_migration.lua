local M = {}

local function copy(store, from, to, reshape)
	local moved = 0
	for _, id in ipairs(store:record_ids(from)) do
		local record = store:get_record(from, id)
		if record and not store:get_record(to, id) then
			store:update_record(to, id, function()
				return reshape(record)
			end)
			moved = moved + 1
		end
	end
	return moved
end

local function to_mandatum(record)
	record.expeditio = record.expeditio or record.epic
	record.assignee = record.assignee or record.agent
	record.epic, record.agent = nil, nil
	return record
end

local entry_kinds = { epic = "expeditio", todo = "mandatum" }

local function reshape_screen(record)
	local touched = false
	if record.entry and entry_kinds[record.entry.kind] then
		record.entry.kind = entry_kinds[record.entry.kind]
		touched = true
	end
	for old, new in pairs(entry_kinds) do
		if record.draft and record.draft[old] ~= nil then
			record.draft[new], record.draft[old] = record.draft[old], nil
			touched = true
		end
	end
	if record.draft and record.draft.in_epic ~= nil then
		record.draft.in_expeditio, record.draft.in_epic = record.draft.in_epic, nil
		touched = true
	end
	return touched and record or false
end

local function retarget_screens(store)
	local changed = 0
	for _, id in ipairs(store:record_ids("conversation_screens")) do
		store:update_record("conversation_screens", id, function(record)
			local shaped = record and reshape_screen(record)
			changed = changed + (shaped and 1 or 0)
			return shaped
		end)
	end
	return changed
end

local function rename_drafts(store)
	local dir, renamed = store.paths.drafts, 0
	for _, name in ipairs(store.fs.list(dir)) do
		for old, new in pairs(entry_kinds) do
			local rest = name:match("^" .. old .. "%-(.+)$")
			local target = rest and (dir .. "/" .. new .. "-" .. rest)
			if target and not store.fs.read(target) then
				store.fs.write(target, store.fs.read(dir .. "/" .. name) or "")
				renamed = renamed + 1
			end
		end
	end
	return renamed
end

function M.run(store)
	return {
		screens = retarget_screens(store),
		drafts = rename_drafts(store),
		expeditiones = copy(store, "epics", "expeditiones", function(record)
			return record
		end),
		mandata = copy(store, "todos", "mandata", to_mandatum),
	}
end

return M
