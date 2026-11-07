local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("ExpeditioEntryViewModel", { "id", "name", "kind", "order", "card", "root", "waiting", "expeditio" })
