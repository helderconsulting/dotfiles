vim.pack.add({
	"https://github.com/mason-org/mason.nvim",
})
require("mason").setup({
	ui = {
		border = "none",
		icons = {
			package_installed = "✓",
			package_pending = "➜",
			package_uninstalled = "✗",
		},
	},
})

local M = {}

function M.ensure_installed(on_done)
	local registry = require("mason-registry")
	registry.refresh(function()
		local pending = 0
		local failed = {}
		local function finish()
			if pending == 0 and on_done then
				on_done(failed)
			end
		end
		for _, name in ipairs(require("packs.tools").mason) do
			local ok, pkg = pcall(registry.get_package, name)
			if ok and not pkg:is_installed() and not pkg:is_installing() then
				pending = pending + 1
				pkg:install({}, function(success)
					if not success then
						table.insert(failed, name)
					end
					pending = pending - 1
					finish()
				end)
			elseif not ok then
				table.insert(failed, name)
			end
		end
		finish()
	end)
end

vim.keymap.set("n", "<leader>L", function()
	require("mason.ui").open()
end, { desc = "Open language tools" })

return M
