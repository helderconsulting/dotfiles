---@brief
---
--- https://github.com/antonk52/cssmodules-language-server
---
--- Autocompletion and go-to-definition for CSS Modules class names
--- (`styles.foo`) referenced from JS/TS/JSX/TSX, resolving into the
--- imported `*.module.css` file.

---@type vim.lsp.Config
return {
	cmd = function(dispatchers, config)
		local cmd = "cssmodules-language-server"
		if (config or {}).root_dir then
			local local_cmd = vim.fs.joinpath(config.root_dir, "node_modules/.bin", cmd)
			if vim.fn.executable(local_cmd) == 1 then
				cmd = local_cmd
			end
		end
		return vim.lsp.rpc.start({ cmd }, dispatchers)
	end,
	filetypes = { "javascript", "javascriptreact", "typescript", "typescriptreact" },
	root_markers = { "package.json" },
}
