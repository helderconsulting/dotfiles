local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("TurnDto", { "prompt", "from", "reply", "at", "queued" })
