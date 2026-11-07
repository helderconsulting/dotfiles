local DataClass = require("workspace.shared.lib.data_class")

local LegionThreadViewModel = DataClass.define("LegionThreadViewModel", { "items", "unread" })

function LegionThreadViewModel:index_of(id)
	for i, item in ipairs(self.items) do
		if item.id == id then
			return i
		end
	end
end

function LegionThreadViewModel:latest_turn()
	for _, item in ipairs(self.items) do
		if item.depth == 0 and item.id ~= "ranks" then
			return item
		end
	end
	return self.items[1]
end

return LegionThreadViewModel
