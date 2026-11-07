local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("ResumeMilesCommand", { "miles_id", "cwd", "prompt" })
