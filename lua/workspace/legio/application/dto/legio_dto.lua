local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("LegioDto", { "id", "name", "cognomen", "munus", "duty", "roles", "deployed", "expeditio", "annales", "mos_maiorum", "cohors", "ranks" })
