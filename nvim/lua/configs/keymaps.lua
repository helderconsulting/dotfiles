vim.keymap.set("n", "Q", "<nop>")
vim.keymap.set({ "n" }, "<C-space>i", vim.lsp.buf.hover, { desc = "more info" })
vim.keymap.set({ "n" }, "<C-space>d", vim.diagnostic.open_float, { desc = "show diagnostics" })
vim.keymap.set({ "n" }, "<C-space>r", vim.lsp.buf.rename, { desc = "rename variable" })
vim.keymap.set({ "n", "x" }, "<C-space>a", function()
	local ok, fzf = pcall(require, "fzf-lua")
	local function filter(action)
		return action and action.disabled == nil
	end
	if ok then
		fzf.lsp_code_actions({
			filter = filter,
			winopts = {
				height = 0.35,
				width = 1.00,
				row = 1.00,
				border = "none",
				preview = { hidden = "hidden" },
			},
		})
	else
		vim.lsp.buf.code_action({ filter = filter })
	end
end, { desc = "show code actions" })

vim.keymap.set("n", "<leader>-", ":bd<cr>", { desc = "close buffer" })
vim.keymap.set("n", "<leader>W", ":wa<cr>", { desc = "save all" })
vim.keymap.set("n", "<leader>w", ":w<cr>", { desc = "save file" })
-- Move between windows; at the edge of Neovim hand the move to WezTerm, which continues into the
-- next pane or AeroSpace window (see wezterm/navigate.lua). The counter makes a repeated direction
-- still a change for WezTerm's user-var-changed event.
local nav_count = 0
local function move(wincmd, direction)
	return function()
		local win = vim.api.nvim_get_current_win()
		vim.cmd.wincmd(wincmd)
		if vim.api.nvim_get_current_win() == win and vim.env.WEZTERM_PANE then
			nav_count = nav_count + 1
			local value = vim.base64.encode(direction .. ":" .. nav_count)
			vim.api.nvim_ui_send(("\27]1337;SetUserVar=nav=%s\7"):format(value))
		end
	end
end
vim.keymap.set("n", "<M-Left>", move("h", "Left"), { desc = "move to left window" })
vim.keymap.set("n", "<M-Right>", move("l", "Right"), { desc = "move to right window" })
vim.keymap.set("n", "<M-Up>", move("k", "Up"), { desc = "move to window above" })
vim.keymap.set("n", "<M-Down>", move("j", "Down"), { desc = "move to window below" })
