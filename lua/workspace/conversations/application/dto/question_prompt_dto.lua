local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("QuestionPromptDto", { "question", "header", "multi_select", "options" })
