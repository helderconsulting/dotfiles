local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("ReviewRecipientDto", { "id", "name", "status", "worktree", "branch", "busy" })
