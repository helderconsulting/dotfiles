local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("CommentDto", { "id", "root", "state", "key", "path", "rev", "line1", "line2", "text", "images", "reply", "remote", "location", "summary", "is_draft", "is_open" })
