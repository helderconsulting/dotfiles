local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("StartMilesCommand", { "cwd", "prompt", "id", "provider", "model", "mode" })
