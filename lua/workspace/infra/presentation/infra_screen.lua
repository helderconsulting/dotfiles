local Model = require("workspace.shared.lib.model")

local InfraScreen = Model.extend({
	kind = "infra_screens",
	fields = { "id", "docker" },
})

function InfraScreen:report_docker(summary)
	self.docker = summary
end

return InfraScreen
