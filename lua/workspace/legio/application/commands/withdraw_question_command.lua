local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("WithdrawQuestionCommand", { "question_id", "only_unseen" })
