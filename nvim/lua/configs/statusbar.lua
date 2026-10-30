-- Neovim's status lives in the WezTerm agent bar instead of a statusline and tabline: mode, buffers,
-- diagnostics, LSP progress and cursor position go to WezTerm as one JSON user var
-- (nvim_status), drawn by wezterm/agents.lua in this pane's entry. Outside WezTerm nothing changes.
if not vim.env.WEZTERM_PANE then
	return
end

vim.o.laststatus = 0
vim.o.showtabline = 0

local modes = {
	n = "normal",
	no = "normal",
	i = "insert",
	ic = "insert",
	v = "visual",
	V = "v-line",
	["\22"] = "v-block",
	s = "select",
	S = "s-line",
	R = "replace",
	c = "command",
	t = "terminal",
	nt = "normal",
}

-- Listed file buffers of the current project (the cwd follows the focused agent), so switching
-- agents switches the buffers shown in the bar too.
local function buffers()
	local list, current, cwd = {}, vim.api.nvim_get_current_buf(), vim.fn.getcwd()
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		local name = vim.api.nvim_buf_get_name(buf)
		if vim.bo[buf].buflisted and vim.bo[buf].buftype == "" and name ~= "" and vim.fs.relpath(cwd, name) then
			table.insert(list, {
				name = vim.fs.basename(name),
				current = buf == current,
				modified = vim.bo[buf].modified,
			})
		end
	end
	return list
end

local function status()
	local counts = vim.diagnostic.count(0)
	local s = vim.diagnostic.severity
	local pos = vim.api.nvim_win_get_cursor(0)
	return {
		mode = modes[vim.api.nvim_get_mode().mode] or vim.api.nvim_get_mode().mode,
		buffers = buffers(),
		errors = counts[s.ERROR] or 0,
		warnings = counts[s.WARN] or 0,
		lsp = vim.lsp.status(),
		pos = pos[1] .. ":" .. (pos[2] + 1),
	}
end

local last
local function send()
	local ok, payload = pcall(function()
		return vim.json.encode(status())
	end)
	if not ok or payload == last then
		return
	end
	last = payload
	vim.api.nvim_ui_send(("\27]1337;SetUserVar=nvim_status=%s\7"):format(vim.base64.encode(payload)))
end

-- Many events fire in bursts (cursor moves, buffer switches); send once they settle.
local timer = vim.uv.new_timer()
local function schedule_send()
	timer:start(30, 0, vim.schedule_wrap(send))
end

local group = vim.api.nvim_create_augroup("StatusBar", { clear = true })
vim.api.nvim_create_autocmd({
	"VimEnter",
	"ModeChanged",
	"BufEnter",
	"BufAdd",
	"BufDelete",
	"BufWipeout",
	"BufModifiedSet",
	"BufWritePost",
	"DiagnosticChanged",
	"LspProgress",
	"CursorMoved",
	"CursorMovedI",
	"DirChanged",
}, { group = group, callback = schedule_send })
vim.api.nvim_create_autocmd("VimLeavePre", {
	group = group,
	callback = function()
		vim.api.nvim_ui_send("\27]1337;SetUserVar=nvim_status=\7")
	end,
})
