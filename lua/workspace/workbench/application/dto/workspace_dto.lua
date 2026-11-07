local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("WorkspaceDto", { "id", "tab", "window", "root", "mode", "panes", "opened" })
