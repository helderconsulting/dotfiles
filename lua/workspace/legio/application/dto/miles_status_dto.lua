local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("MilesStatusDto", { "name", "post", "state", "doing", "running", "quiet", "waiting", "depth", "stopped" })
