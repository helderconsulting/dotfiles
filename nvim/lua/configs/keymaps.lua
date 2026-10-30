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
vim.keymap.set("n", "<M-Left>", "<C-w>h", { desc = "move to left window" })
vim.keymap.set("n", "<M-Right>", "<C-w>l", { desc = "move to right window" })
vim.keymap.set("n", "<M-Up>", "<C-w>k", { desc = "move to window above" })
vim.keymap.set("n", "<M-Down>", "<C-w>j", { desc = "move to window below" })
