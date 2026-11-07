local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("ExpeditioProgressDto", { "total", "done", "in_progress", "open", "fraction" })
