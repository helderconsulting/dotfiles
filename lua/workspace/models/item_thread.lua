local ItemThread = {}
ItemThread.__index = ItemThread

function ItemThread.new(list, opts)
	opts = opts or {}
	return setmetatable({ items = list, unread = 0, entry_id = opts.entry }, ItemThread)
end

function ItemThread:index_of(id)
	for i, item in ipairs(self.items) do
		if item.id == id then
			return i
		end
	end
end

function ItemThread:latest_turn()
	local i = self.entry_id and self:index_of(self.entry_id)
	return i and self.items[i] or self.items[1]
end

return ItemThread
