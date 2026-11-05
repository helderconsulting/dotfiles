vim.pack.add({
	{ src = "https://github.com/Saghen/blink.cmp", version = vim.version.range("1.*") },
})

require("blink.cmp").setup({
	enabled = function()
		return not vim.tbl_contains({ "gitcommit", "NeogitCommitMessage" }, vim.bo.filetype)
	end,
	signature = {
		enabled = true,
		window = { border = "none" },
	},
	keymap = {
		preset = "super-tab",
		["<C-space>"] = { "show", "show_documentation", "hide_documentation" },
	},
	appearance = {
		use_nvim_cmp_as_default = false,
		nerd_font_variant = "mono",
	},
	completion = {
		documentation = {
			auto_show = false,
			window = { border = "none" },
		},
		ghost_text = { enabled = false },
		menu = {
			border = "none",
			draw = {
				columns = { { "label", "label_description", gap = 1 } },
			},
		},
	},
	sources = {
		default = { "lsp", "path", "snippets", "buffer" },
		providers = {
			claude = { name = "claude", module = "configs.claude_source", score_offset = 10 },
		},
	},
	cmdline = {
		enabled = true,
		keymap = { preset = "super-tab" },
		sources = function()
			local type = vim.fn.getcmdtype()
			if type == "/" or type == "?" then
				return { "buffer" }
			end
			if type == ":" then
				return require("configs.app").role == "conversation" and { "claude", "cmdline" } or { "cmdline" }
			end
			return {}
		end,
		completion = { menu = { auto_show = true } },
	},
	fuzzy = { implementation = "prefer_rust_with_warning" },
})
