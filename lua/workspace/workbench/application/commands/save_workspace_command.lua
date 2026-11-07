local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("SaveWorkspaceCommand", { "id", "tab", "window", "root", "mode", "panes", "opened" })
