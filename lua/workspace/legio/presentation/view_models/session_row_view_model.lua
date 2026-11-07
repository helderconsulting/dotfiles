local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("SessionRowViewModel", { "id", "miles_id", "path", "name", "cwd", "root", "mtime", "running", "drafting", "busy", "state", "word", "kind", "unread", "order", "place", "on_cli", "uses_extra", "meter", "search_word", "search_detail", "target", "needs_resume", "toggle", "on_sdk", "cannot_end", "cannot_interrupt", "cannot_continue", "cannot_move", "sort_name", "contubernium_label", "standing", "role", "mark", "leader", "indent", "bar", "component", "space_before" })
