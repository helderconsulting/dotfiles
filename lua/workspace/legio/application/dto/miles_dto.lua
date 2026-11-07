local DataClass = require("workspace.shared.lib.data_class")

return DataClass.define("MilesDto", { "id", "short", "name", "title", "state", "tone", "cwd", "root", "branch", "worktree", "pane", "host", "running", "busy", "needs_you", "hosted", "on_sdk", "on_cli", "channel", "unread", "activity", "read_at", "updated", "progress", "progress_tone", "provider", "model", "model_label", "mode", "mode_label", "context_fraction", "plan_label", "uses_extra", "fallback_reason", "can_continue", "continue_reason", "held", "can_release", "rank", "standing", "role", "legio" })
