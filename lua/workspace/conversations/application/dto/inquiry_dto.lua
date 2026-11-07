local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define(
	"InquiryDto",
	{ "id", "session", "cwd", "tool", "is_question", "unseen", "pending", "decision", "prompts", "details", "choices" }
)
