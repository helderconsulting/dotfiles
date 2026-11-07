local M = {}

function M.send_keys(pane, text, paste, done)
	local cmd = { "wezterm", "cli", "send-text", "--pane-id", tostring(pane) }
	if not paste then
		table.insert(cmd, "--no-paste")
	end
	table.insert(cmd, text)
	vim.system(cmd, { text = true }, vim.schedule_wrap(function(res)
		if res.code ~= 0 then
			vim.notify("couldn't reach the agent's pane: " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
		end
		if done then
			done(res.code == 0)
		end
	end))
end

return M
