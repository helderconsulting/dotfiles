local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("ExpeditioDto", { "id", "title", "root", "from", "created", "status", "tone", "progress", "mandata", "waiting", "next_up", "finished" })
