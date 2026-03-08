---@type vim.lsp.Config
return {
	cmd = { "lua-language-server" },
	filetypes = { "lua" },
	root_markers = {
		".luarc.json",
		".luarc.jsonc",
		".stylua.toml",
	},
	settings = {
		Lua = {
			runtime = {
				version = "LuaJIT",
			},
			format = { enable = false },
			codeLens = { enable = true },
			hint = {
				enable = true,
				arrayIndex = "Disable",
			},
			telemetry = {
				enable = false,
			},
			workspace = {
				checkThirdParty = false,
				library = {
					vim.env.VIMRUNTIME,
					"${3rd}/luv/library",
				},
			},
		},
	},
}
