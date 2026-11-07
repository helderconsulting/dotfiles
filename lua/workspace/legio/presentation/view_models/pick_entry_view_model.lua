local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("PickEntryViewModel", { "tag", "provider", "value", "label", "description", "current", "miles_id" })
