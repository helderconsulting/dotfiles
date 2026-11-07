local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("AddMandatumCommand", { "root", "expeditio_id", "expeditio_title", "title", "description", "criteria", "text", "from" })
