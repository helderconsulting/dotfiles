vim.pack.add({
	"https://github.com/ibhagwan/fzf-lua",
})

local fzf = require("fzf-lua")
fzf.setup({
	files = {
		fd_opts = "--type f --hidden --follow --exclude .git",
		rg_opts = "--files --hidden --follow -g '!.git'",
	},
	grep = {
		rg_opts = "--hidden --follow --smart-case --no-heading --line-number --column --color=always -g '!.git' -g '!node_modules/*' -g '!dist/*' -g '!.next/*' -g '!build/*' -g '!target/*' -g '!*.lock'",
	},
	file_ignore_patterns = {
		"node_modules/",
		"dist/",
		".next/",
		".git/",
		".gitlab/",
		"build/",
		"target/",
		"package-lock.json",
		"pnpm-lock.yaml",
		"yarn.lock",
	},
	winopts = {
		height = 0.40,
		width = 1.00,
		row = 1.00,
		border = "none",
		on_create = function(e)
			vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "FocusLost" }, {
				buffer = e.bufnr,
				once = true,
				callback = function()
					local ok, fzf = pcall(require, "fzf-lua")
					if ok then
						fzf.hide()
					end
				end,
			})
		end,
		preview = {
			border = "none",
			hidden = "nohidden",
		},
	},
	hls = {
		-- Give the cwd header the same LED panel treatment as the wezterm directory pill
		fzf_header = { fg = "#77DD77", bg = "#0F2A0F", bold = true },
	},
	fzf_colors = {
		-- mfd-hud palette (all hardcoded hex — group refs not reliable in fzf):
		--   bg=#060C06  fg=#55BB55  dim=#2E5C2E  bright=#77DD77  led-bg=#0F2A0F
		["fg"] = "#55BB55", -- regular entry text
		["fg+"] = "#77DD77", -- selected entry text — bump to bright
		["bg"] = "#060C06", -- main background
		["bg+"] = "#0F2A0F", -- selected line — LED panel
		["hl"] = "#77DD77", -- fuzzy matched chars in list
		["hl+"] = "#77DD77", -- fuzzy matched chars in selected line
		["pointer"] = "#77DD77", -- cursor pointer (▶)
		["marker"] = "#77DD77", -- multi-select marker
		["prompt"] = "#2E5C2E", -- ">" prompt prefix — readable-dim
		["query"] = "#55BB55", -- typed query text
		["info"] = "#2E5C2E", -- result count — readable-dim
		["border"] = "#1A3018", -- borders (if used)
		["separator"] = "#1A3018", -- preview separator
		["scrollbar"] = "#2E5C2E", -- scrollbar track
		["header"] = "#77DD77", -- cwd path text — bright
		["gutter"] = "#060C06", -- left gutter — match bg, no bleed
	},
	fzf_opts = {
		["--no-info"] = "",
		["--pointer"] = " ",
		["--marker"] = " ",
	},
	defaults = {
		git_icons = false,
		file_icons = false,
	},
})
fzf.register_ui_select({
	-- Use fzf-lua UI for vim.ui.select (e.g., LSP code actions)
	winopts = {
		height = 0.30,
		width = 0.60,
		row = 0.40,
		border = "none",
		preview = { hidden = "hidden" },
	},
})
vim.keymap.set("n", "<leader>f", fzf.files, { desc = "search across all files" })
vim.keymap.set("n", "<leader>F", fzf.grep_cword, { desc = "search word across all files" })
vim.keymap.set("n", "<leader>B", fzf.buffers, { desc = "search in buffers" })
vim.keymap.set("n", "<leader>c", function()
	fzf.files({ cwd = "~/.config/nvim/" })
end, { desc = "search vim configurations" })
vim.keymap.set("n", "<leader>h", fzf.undotree, { desc = "browse current file changes" })
vim.keymap.set("n", "<leader>s", fzf.live_grep_native, { desc = "find term in current project" })
vim.keymap.set("n", "<leader>e", fzf.lsp_workspace_diagnostics, { desc = "search diagnostics in current project" })
