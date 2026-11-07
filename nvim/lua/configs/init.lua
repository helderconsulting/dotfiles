require("configs.settings")
if require("workspace.workbench.presentation.nvim.app").role ~= "editor" then
	vim.o.shadafile = "NONE"
end
require("configs.keymaps")
require("configs.lsp")
require("configs.pack")
require("configs.projects")
require("configs.statusbar")
for _, name in ipairs(require("configs.roles").modules or {}) do
	require(name)
end

vim.api.nvim_create_autocmd("UILeave", {
	callback = function()
		vim.defer_fn(function()
			if #vim.api.nvim_list_uis() > 0 then
				return
			end
			for _, buf in ipairs(vim.api.nvim_list_bufs()) do
				if vim.bo[buf].modified and vim.bo[buf].buftype == "" then
					return
				end
			end
			vim.cmd("qa!")
		end, 3000)
	end,
})
