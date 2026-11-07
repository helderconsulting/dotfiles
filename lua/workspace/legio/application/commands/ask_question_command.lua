local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("AskQuestionCommand", { "session", "request", "tool", "input", "suggestions", "cwd" })
