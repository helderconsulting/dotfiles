local mandatum_request = require("workspace.conversations.domain.mandatum_request")

local M = {}

function M.run()
	local input = io.read("*a")
	local ok, payload = pcall(vim.json.decode, input)
	local command = ok and type(payload) == "table" and type(payload.tool_input) == "table" and payload.tool_input.command or nil
	if mandatum_request.adds(command) then
		io.write(vim.json.encode({
			hookSpecificOutput = {
				hookEventName = "PreToolUse",
				permissionDecision = "ask",
				permissionDecisionReason = "Adding a todo or mandatum needs your approval.",
			},
		}))
	end
	return 0
end

return M
