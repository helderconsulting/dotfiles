local M = {}

M.features = { "legio", "workflow", "conversations", "workbench", "infra" }

local built = setmetatable({}, { __mode = "k" })

function M.build(store, opts)
	if built[store] then
		return built[store]
	end
	local services = {}
	for _, feature in ipairs(M.features) do
		require("workspace." .. feature .. ".composition").register(services, store, opts or {})
	end
	built[store] = services
	return services
end

return M
