vim.pack.add({
	"https://github.com/nvim-treesitter/nvim-treesitter",
	"https://github.com/nvim-treesitter/nvim-treesitter-textobjects",
})

vim.api.nvim_create_autocmd("PackChanged", {
	desc = "Handle nvim-treesitter updates",
	group = vim.api.nvim_create_augroup("nvim-treesitter-pack-changed-update-handler", { clear = true }),
	callback = function(event)
		if event.data.kind == "update" then
			local ok = pcall(vim.cmd, "TSUpdate")
			if ok then
				vim.notify("TSUpdate completed successfully!", vim.log.levels.INFO)
			else
				vim.notify("TSUpdate command not available yet, skipping", vim.log.levels.WARN)
			end
		end
	end,
})
local ts = require("nvim-treesitter")
-- https://github.com/nvim-treesitter/nvim-treesitter/blob/main/SUPPORTED_LANGUAGES.md
ts.install({
	"c",
	"lua",
	"luadoc",
	"glimmer",
	"javascript",
	"comment",
	"query",
	"vim",
	"vimdoc",
	"bash",
	"typescript",
	"json",
	"rust",
	"dockerfile",
	"editorconfig",
	"gitcommit",
	"gitdiff",
	"http",
})
vim.treesitter.language.register("glimmer", "handlebars")

require("nvim-treesitter-textobjects").setup({
	select = {
		lookahead = true,
	},
	move = {
		set_jumps = true,
	},
})

local ts_select = require("nvim-treesitter-textobjects.select")
vim.keymap.set({ "x", "o" }, "a=", function()
	ts_select.select_textobject("@assignment.outer", "textobjects")
end, { desc = "Select outer part of an assignment" })

vim.keymap.set({ "x", "o" }, "i=", function()
	ts_select.select_textobject("@assignment.inner", "textobjects")
end, { desc = "Select inner part of an assignment" })

vim.keymap.set({ "x", "o" }, "l=", function()
	ts_select.select_textobject("@assignment.lhs", "textobjects")
end, { desc = "Select left hand side of an assignment" })

vim.keymap.set({ "x", "o" }, "r=", function()
	ts_select.select_textobject("@assignment.rhs", "textobjects")
end, { desc = "Select right hand side of an assignment" })

vim.keymap.set({ "x", "o" }, "af", function()
	ts_select.select_textobject("@function.outer", "textobjects")
end, { desc = "Select outer part of an function" })

vim.keymap.set({ "x", "o" }, "if", function()
	ts_select.select_textobject("@function.inner", "textobjects")
end, { desc = "Select inner part of an function" })

vim.keymap.set({ "x", "o" }, "ac", function()
	ts_select.select_textobject("@class.outer", "textobjects")
end, { desc = "Select outer part of an class" })

vim.keymap.set({ "x", "o" }, "ic", function()
	ts_select.select_textobject("@class.inner", "textobjects")
end, { desc = "Select inner part of an class" })

vim.keymap.set({ "x", "o" }, "ap", function()
	ts_select.select_textobject("@parameter.outer", "textobjects")
end, { desc = "Select outer part of an argument" })

vim.keymap.set({ "x", "o" }, "ip", function()
	ts_select.select_textobject("@parameter.inner", "textobjects")
end, { desc = "Select inner part of an argument" })

vim.keymap.set({ "x", "o" }, "ai", function()
	ts_select.select_textobject("@conditional.outer", "textobjects")
end, { desc = "Select outer part of an conditional" })

vim.keymap.set({ "x", "o" }, "ii", function()
	ts_select.select_textobject("@conditional.inner", "textobjects")
end, { desc = "Select inner part of an conditional" })

vim.keymap.set({ "x", "o" }, "al", function()
	ts_select.select_textobject("@loop.outer", "textobjects")
end, { desc = "Select outer part of an conditional" })

vim.keymap.set({ "x", "o" }, "il", function()
	ts_select.select_textobject("@loop.inner", "textobjects")
end, { desc = "Select inner part of an conditional" })

vim.keymap.set({ "x", "o" }, "ar", function()
	ts_select.select_textobject("@return.outer", "textobjects")
end, { desc = "Select outer part of an conditional" })

vim.keymap.set({ "x", "o" }, "ir", function()
	ts_select.select_textobject("@return.inner", "textobjects")
end, { desc = "Select inner part of an conditional" })

vim.keymap.set({ "x", "o" }, "a/", function()
	ts_select.select_textobject("@comment.outer", "textobjects")
end, { desc = "Select outer comment" })

vim.keymap.set({ "x", "o" }, "i/", function()
	ts_select.select_textobject("@comment.inner", "textobjects")
end, { desc = "Select inner comment" })

local ts_move = require("nvim-treesitter-textobjects.move")
vim.keymap.set({ "n", "x", "o" }, "]f", function()
	ts_move.goto_next_start("@function.outer")
end, { desc = "Next function call start" })

vim.keymap.set({ "n", "x", "o" }, "]c", function()
	ts_move.goto_next_start("@class.outer")
end, { desc = "Next class start" })

vim.keymap.set({ "n", "x", "o" }, "]i", function()
	ts_move.goto_next_start("@conditional.outer")
end, { desc = "Next conditional start" })

vim.keymap.set({ "n", "x", "o" }, "]l", function()
	ts_move.goto_next_start("@loop.outer")
end, { desc = "Next loop start" })

vim.keymap.set({ "n", "x", "o" }, "]F", function()
	ts_move.goto_next_end("@function.outer")
end, { desc = "Next method/function def end" })
vim.keymap.set({ "n", "x", "o" }, "]C", function()
	ts_move.goto_next_end("@class.outer")
end, { desc = "Next class end" })
vim.keymap.set({ "n", "x", "o" }, "]I", function()
	ts_move.goto_next_end("@conditional.outer")
end, { desc = "Next conditional end" })
vim.keymap.set({ "n", "x", "o" }, "]L", function()
	ts_move.goto_next_end("@loop.outer")
end, { desc = "Next loop end" })

vim.keymap.set({ "n", "x", "o" }, "]/", function()
	ts_move.goto_next_start("@comment.outer")
end, { desc = "Next comment start" })

vim.keymap.set({ "n", "x", "o" }, "[f", function()
	ts_move.goto_previous_start("@function.outer")
end, { desc = "Prev method/function def start" })
vim.keymap.set({ "n", "x", "o" }, "[c", function()
	ts_move.goto_previous_start("@class.outer")
end, { desc = "Prev class start" })
vim.keymap.set({ "n", "x", "o" }, "[i", function()
	ts_move.goto_previous_start("@conditional.outer")
end, { desc = "Prev conditional start" })
vim.keymap.set({ "n", "x", "o" }, "[l", function()
	ts_move.goto_previous_start("@loop.outer")
end, { desc = "Prev loop start" })

vim.keymap.set({ "n", "x", "o" }, "[F", function()
	ts_move.goto_previous_end("@function.outer")
end, { desc = "Prev method/function def end" })
vim.keymap.set({ "n", "x", "o" }, "[C", function()
	ts_move.goto_previous_end("@class.outer")
end, { desc = "Prev class end" })
vim.keymap.set({ "n", "x", "o" }, "[I", function()
	ts_move.goto_previous_end("@conditional.outer")
end, { desc = "Prev conditional end" })
vim.keymap.set({ "n", "x", "o" }, "[L", function()
	ts_move.goto_previous_end("@loop.outer")
end, { desc = "Prev loop end" })

vim.keymap.set({ "n", "x", "o" }, "[/", function()
	ts_move.goto_previous_start("@comment.outer")
end, { desc = "Prev comment start" })

vim.api.nvim_create_autocmd("FileType", {
	pattern = "*",
	callback = function(args)
		local ok = pcall(vim.treesitter.start, args.buf)
		if ok then
			vim.wo[0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
			vim.wo[0].foldmethod = "expr"
			vim.wo[0].foldlevel = 99
			vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
		end
	end,
})
