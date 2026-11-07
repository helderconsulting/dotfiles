local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("AmendMandatumCommand", { "mandatum_id", "title", "description", "criteria" })
