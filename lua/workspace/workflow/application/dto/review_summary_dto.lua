local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("ReviewSummaryDto", { "root", "state", "ready", "approved", "note", "draft", "sent", "resolved" })
