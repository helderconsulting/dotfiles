local M = {}

function M.check()
	local tools = require("packs.tools")

	vim.health.start("system tools")
	for _, bin in ipairs(tools.binaries) do
		if vim.fn.executable(bin[1]) == 1 then
			vim.health.ok(bin[1])
		elseif bin.optional then
			vim.health.info(bin[1] .. " not found (optional, " .. bin[2] .. ")")
		else
			vim.health.error(bin[1] .. " not found (" .. bin[2] .. ")", "run ~/.config/nvim/install.sh")
		end
	end

	vim.health.start("treesitter parsers")
	local ok_ts, ts_config = pcall(require, "nvim-treesitter.config")
	if ok_ts then
		local installed = {}
		for _, lang in ipairs(ts_config.get_installed()) do
			installed[lang] = true
		end
		for _, lang in ipairs(tools.parsers) do
			if installed[lang] then
				vim.health.ok(lang)
			else
				vim.health.warn(lang .. " not installed", "open a file to install it, or run :TSInstall " .. lang)
			end
		end
	else
		vim.health.info("nvim-treesitter not loaded yet, open a file first")
	end

	vim.health.start("mason tools")
	local ok_mason, registry = pcall(require, "mason-registry")
	if ok_mason then
		for _, name in ipairs(tools.mason) do
			if registry.is_installed(name) then
				vim.health.ok(name)
			else
				vim.health.warn(name .. " not installed", "open :Mason, or restart nvim to install it")
			end
		end
	else
		vim.health.info("mason not loaded")
	end
end

return M
