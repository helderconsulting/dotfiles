local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("CommentViewModel", { "id", "root", "key", "path", "rev", "line1", "line2", "text", "images", "reply", "state", "is_draft", "location", "summary", "sign_highlight", "line_highlight", "status", "list_label" })
