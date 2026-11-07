local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("LegioEntryViewModel", { "id", "legio_id", "name", "kind", "order", "card", "deployed", "component", "space_before" })
