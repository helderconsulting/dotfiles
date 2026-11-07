local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("EntryDto", { "id", "name", "word", "kind", "detail", "find_detail", "order", "refs", "view_key", "source" })
