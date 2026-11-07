local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("AwaitingTurnDto", { "text", "at", "started" })
