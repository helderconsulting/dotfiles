local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("RemoteChangesDto", { "added", "reopened", "closed" })
