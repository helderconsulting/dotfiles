vim.pack.add({
	"https://github.com/folke/tokyonight.nvim",
})
local ok_tokyo, tokyonight = pcall(require, "tokyonight")
if ok_tokyo then
	tokyonight.setup()
	vim.cmd([[colorscheme tokyonight]])
end
