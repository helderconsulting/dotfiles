local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("AgentdStatusDto", { "state", "reason", "since", "health", "health_tone" })
