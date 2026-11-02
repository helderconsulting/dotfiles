require("packs.theme")

local on_open_group = vim.api.nvim_create_augroup("OnOpen", { clear = true })
vim.api.nvim_create_autocmd({ "BufReadPre", "BufNewFile" }, {
	group = on_open_group,
	once = true,
	callback = function()
		require("packs.lint")
	end,
})

local after_open_group = vim.api.nvim_create_augroup("AfterOpen", { clear = true })
vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile" }, {
	group = after_open_group,
	once = true,
	callback = function()
		require("packs.treesitter")
		require("packs.undotree")
		require("packs.conform")
		require("packs.paste")
		require("packs.markdown-renderer")
	end,
})

local enter_group = vim.api.nvim_create_augroup("OnEnter", { clear = true })
vim.api.nvim_create_autocmd("VimEnter", {
	group = enter_group,
	once = true,
	callback = function()
		local later = {}
		if vim.g.sidebar then
			require("packs.whichkey")
		elseif vim.g.docker_view then
			require("packs.whichkey")
			later = { "packs.git" }
		else
			require("packs.fzf")
			require("packs.oil")
			require("packs.mason")
			require("packs.whichkey")
			require("packs.paste")
			later = { "packs.git", "packs.dap", "packs.rustacean", "packs.neotest" }
		end
		vim.defer_fn(function()
			for _, name in ipairs(later) do
				require(name)
			end
		end, 20)
	end,
})

local insert_group = vim.api.nvim_create_augroup("OnInsert", { clear = true })
vim.api.nvim_create_autocmd({ "InsertEnter", "CmdlineEnter" }, {
	pattern = "*",
	group = insert_group,
	once = true,
	callback = function()
		require("packs.blink")
		require("packs.autopairs")
	end,
})
