local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("DeployLegioCommand", { "legio_id", "expeditio_id", "provider", "mode" })
