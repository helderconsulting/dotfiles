local DataClass = require("workspace.shared.lib.data_class")

local ExpeditioThreadViewModel = DataClass.define("ExpeditioThreadViewModel", { "items", "unread", "entry_id" })

function ExpeditioThreadViewModel:index_of(id)
	for i, item in ipairs(self.items) do
		if item.id == id then
			return i
		end
	end
end

function ExpeditioThreadViewModel:latest_turn()
	local i = self.entry_id and self:index_of(self.entry_id)
	return i and self.items[i] or self.items[1]
end

return ExpeditioThreadViewModel
