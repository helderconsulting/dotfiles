local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("AlignPlanCommand", { "from", "to", "text" })
