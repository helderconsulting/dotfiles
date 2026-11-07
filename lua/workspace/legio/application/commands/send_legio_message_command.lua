local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("SendLegioMessageCommand", { "from", "to", "text", "kind" })
