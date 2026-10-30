---@brief
---
--- https://github.com/vunguyentuan/vscode-css-variables/tree/master/packages/css-variables-language-server
---
--- Project-wide autocompletion and go-to-definition for CSS custom properties
--- (--vars). Complements css_ls, which only resolves --vars within the
--- current file.

---@type vim.lsp.Config
return {
	cmd = function(dispatchers, config)
		local cmd = "css-variables-language-server"
		if (config or {}).root_dir then
			local local_cmd = vim.fs.joinpath(config.root_dir, "node_modules/.bin", cmd)
			if vim.fn.executable(local_cmd) == 1 then
				cmd = local_cmd
			end
		end
		return vim.lsp.rpc.start({ cmd, "--stdio" }, dispatchers)
	end,
	filetypes = { "css", "scss", "less" },
	root_markers = { "package.json", ".git" },
	settings = {
		cssVariables = {
			lookupFiles = { "**/*.less", "**/*.scss", "**/*.sass", "**/*.css" },
			blacklistFolders = {
				"**/.cache",
				"**/.git",
				"**/.hg",
				"**/.next",
				"**/.svn",
				"**/bower_components",
				"**/CVS",
				"**/dist",
				"**/node_modules",
				"**/tests",
				"**/tmp",
			},
		},
	},
}
