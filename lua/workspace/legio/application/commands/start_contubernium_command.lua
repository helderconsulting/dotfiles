local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("StartContuberniumCommand", { "todo_id", "todo_text", "todo_title", "root", "size", "provider", "model", "mode" })
