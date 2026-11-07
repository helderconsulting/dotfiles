local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("HandMandatumCommand", { "mandatum_id", "from", "to" })
