local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("MandatumDto", { "id", "expeditio", "state", "status", "tone", "title", "text", "description", "criteria", "root", "from", "created", "assignee", "assigned_at", "sent_at", "done_at", "note", "specified", "listed" })
