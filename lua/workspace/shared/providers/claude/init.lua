local M = {}

M.name = "claude"
M.bin = "claude"
M.sdk_package = "@anthropic-ai/claude-agent-sdk"
M.session_env = "CLAUDE_CODE_SESSION_ID"
M.job_env = "CLAUDE_JOB_DIR"

local moments = {
	SessionStart = "start",
	UserPromptSubmit = "prompt",
	PreToolUse = "before_tool",
	PostToolUse = "after_tool",
	PermissionRequest = "permission",
	Notification = "notice",
	Stop = "stop",
	SessionEnd = "end",
}

local transitions = {
	SessionStart = "start",
	UserPromptSubmit = "prompt",
	PostToolUse = "tool",
	PermissionRequest = "ask",
	Stop = "stop",
	SessionEnd = "end",
}

local function transition(name, payload)
	if name == "PreToolUse" then
		return payload.tool_name == "AskUserQuestion" and "ask" or "tool"
	elseif name == "Notification" then
		local kind = payload.notification_type
		return (kind == nil or kind == "permission_prompt" or kind == "elicitation_dialog") and "ask" or nil
	end
	return transitions[name]
end

function M.hook_name(moment)
	for name, m in pairs(moments) do
		if m == moment then
			return name
		end
	end
	return moment
end

function M.session_event(payload)
	local name = payload.hook_event_name
	return {
		session_id = payload.session_id,
		cwd = payload.cwd,
		moment = moments[name] or name,
		transition = transition(name, payload),
		tool_name = payload.tool_name,
		tool_input = payload.tool_input,
		prompt = payload.prompt,
		suggestions = payload.permission_suggestions,
		continuing = payload.stop_hook_active == true,
	}
end

function M.raw(moment, fields)
	local payload = { hook_event_name = M.hook_name(moment) }
	for k, v in pairs(fields or {}) do
		payload[k] = v
	end
	return payload
end

function M.started_event(id, cwd)
	return M.session_event({ session_id = id, hook_event_name = "SessionStart", cwd = cwd })
end

function M.locations(home)
	return {
		sessions = home .. "/.claude/sessions",
		projects = home .. "/.claude/projects",
		commands = home .. "/.claude/commands",
		skills = home .. "/.claude/skills",
	}
end

function M.current_session()
	return vim.env[M.session_env]
end

function M.in_background()
	local dir = vim.env[M.job_env]
	return dir ~= nil and dir ~= ""
end

function M.job_dir()
	return vim.env[M.job_env]
end

function M.model_label(model)
	return model:match("^claude%-(%a+)") or model
end

function M.sdk_installed(dir)
	return vim.uv.fs_stat(dir .. "/node_modules/" .. M.sdk_package) ~= nil
end

function M.background_command(root, resume, shell_quote)
	local resuming = resume and ("--resume " .. resume .. " ") or ""
	return "cd " .. shell_quote(root) .. " && env -u WEZTERM_PANE " .. M.bin .. " " .. resuming .. "--bg"
end

M.sessions_script = "claude-sessions"

setmetatable(M, {
	__index = function(t, key)
		if key == "attach_link" or key == "session_files" or key == "background_cli" then
			local mod = require("workspace.shared.providers.claude." .. key)
			rawset(t, key, mod)
			return mod
		end
	end,
})

return M
