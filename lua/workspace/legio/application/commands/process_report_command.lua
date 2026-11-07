local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("ProcessReportCommand", { "type", "id", "provider", "event", "model", "mode", "plan", "reason", "used", "window", "windows", "overage", "extra", "resets_at" })
