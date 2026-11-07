local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("ActionDto", { "key", "label", "always", "single" })
