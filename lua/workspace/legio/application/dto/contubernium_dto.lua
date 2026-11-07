local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("ContuberniumDto", { "id", "name", "label", "todo", "root", "base", "created", "members" })
