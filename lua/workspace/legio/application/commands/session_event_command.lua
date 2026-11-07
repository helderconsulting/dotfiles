local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("SessionEventCommand", { "payload", "pane", "background", "host", "ask" })
