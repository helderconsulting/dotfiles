local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("SendContuberniumMessageCommand", { "from", "to", "text" })
