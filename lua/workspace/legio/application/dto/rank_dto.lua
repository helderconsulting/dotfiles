local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("RankDto", { "rank", "level", "next", "done", "needed", "unit" })
