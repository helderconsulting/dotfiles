local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define(
	"DraftDto",
	{ "target", "text", "images", "message", "empty", "first_line", "mtime", "created" }
)
