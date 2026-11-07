local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("SaveCommentCommand", { "root", "id", "key", "path", "rev", "line1", "line2", "text", "images" })
