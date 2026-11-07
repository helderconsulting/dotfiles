local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("DeliverMessageCommand", { "miles_id", "cwd", "text", "provider", "model", "mode" })
