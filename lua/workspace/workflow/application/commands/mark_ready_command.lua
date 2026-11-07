local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("MarkReadyCommand", { "root", "note", "session" })
