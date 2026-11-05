vim.api.nvim_create_autocmd("PackChanged", {
	group = vim.api.nvim_create_augroup("PackHooks", { clear = true }),
	callback = function(ev)
		if ev.data.spec.name == "nvim-treesitter" and ev.data.kind == "update" then
			if not ev.data.active then
				vim.cmd.packadd("nvim-treesitter")
			end
			require("nvim-treesitter").update()
		end
	end,
})

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
		local role = require("configs.roles")
		for _, name in ipairs(role.packs or {}) do
			require(name)
		end
		if role.mason then
			require("packs.mason").ensure_installed()
		end
		if role.start then
			vim.schedule(require(role.start).open)
		end
		local later = role.later or {}
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
