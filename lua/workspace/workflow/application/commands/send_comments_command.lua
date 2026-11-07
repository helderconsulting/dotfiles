local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("SendCommentsCommand", { "root", "ids", "agent_id", "lines", "quote" })
