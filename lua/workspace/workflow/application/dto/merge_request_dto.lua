local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("MergeRequestDto", { "root", "iid", "url", "exists", "label", "tone", "card_lines" })
