local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("FileCommentCountsDto", { "path", "draft", "sent", "resolved" })
