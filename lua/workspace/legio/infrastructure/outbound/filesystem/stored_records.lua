local M = {}

function M.get(store, kind, mapper, id)
	local record = id and store:get_record(kind, id)
	return record and mapper.to_domain(record) or nil
end

function M.all(store, kind, mapper)
	local list = {}
	for _, id in ipairs(store:record_ids(kind)) do
		local record = store:get_record(kind, id)
		if record then
			table.insert(list, mapper.to_domain(record))
		end
	end
	return list
end

function M.update(store, kind, mapper, id, fn)
	local model
	store:update_record(kind, id, function(record)
		model = mapper.to_domain(record or { id = id })
		model.id = id
		local result = fn(model, record == nil)
		local transitions = model:take_transitions()
		if result == false or result == "delete" then
			return result, transitions
		end
		return mapper.to_record(model), transitions
	end)
	return model
end

function M.remove(store, kind, id)
	store:update_record(kind, id, function()
		return "delete"
	end)
end

return M
