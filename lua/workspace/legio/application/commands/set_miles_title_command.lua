local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("SetMilesTitleCommand", { "miles_id", "title", "as_member", "create" })
