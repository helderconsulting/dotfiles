local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("ContuberniumStartedDto", { "contubernium_id", "label", "decanus_id", "size", "todo_title" })
