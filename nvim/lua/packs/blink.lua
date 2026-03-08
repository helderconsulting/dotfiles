vim.pack.add({
	"https://github.com/Saghen/blink.cmp",
})

require("blink.cmp").setup({
	signature = {
		enabled = true,
		trigger = {
			enabled = true,
			show_on_keyword = false,
			blocked_trigger_characters = {},
			blocked_retrigger_characters = {},
			show_on_trigger_character = true,
			show_on_insert = true,
			show_on_insert_on_trigger_character = true,
		},
	},
	keymap = { preset = "super-tab" },
	appearance = {
		use_nvim_cmp_as_default = false,
	},
	completion = {
		documentation = { auto_show = false },
	},
	sources = {
		default = { "lsp", "path", "snippets", "buffer" },
	},
	providers = {
		dadbod = { name = "DadBod", module = "vim_dadbod_completion.blink" },
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
