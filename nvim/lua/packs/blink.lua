vim.pack.add({
	"https://github.com/Saghen/blink.cmp",
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
		ghost_text = { enabled = true },
		menu = {
			border = "none",
			draw = {
				columns = { { "label", "label_description", gap = 1 } },
			},
		},
	},
	sources = {
		default = { "lsp", "path", "snippets", "buffer" },
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
				return { "cmdline" }
			end
			return {}
		end,
		completion = { menu = { auto_show = true } },
	},
	fuzzy = { implementation = "prefer_rust_with_warning" },
})

vim.api.nvim_create_autocmd("PackChanged", {
	callback = function(ev)
		local name, kind = ev.data.spec.name, ev.data.kind
		if name == "blink.cmp" and (kind == "install" or kind == "update") then
			vim.system({ "cargo", "build", "--release" }, { cwd = ev.data.path }):wait()
		end
	end,
})
