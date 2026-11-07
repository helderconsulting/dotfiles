local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("ChoiceViewModel", { "key", "label", "description", "decision", "extra", "chosen" })
