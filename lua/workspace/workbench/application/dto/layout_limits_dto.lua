local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("LayoutLimitsDto", { "editor_min", "sidebar_min", "conversation_min" })
