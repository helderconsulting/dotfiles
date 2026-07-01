vim.g.mapleader = " "
vim.opt.nu = false
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.cursorline = true
vim.opt.scrolloff = 10
vim.opt.sidescrolloff = 10

vim.opt.clipboard:append("unnamedplus")
vim.opt.signcolumn = "yes"
vim.opt.tabstop = 4
vim.opt.softtabstop = 4
vim.opt.shiftwidth = 4
vim.opt.showmatch = true
vim.opt.expandtab = true
vim.opt.smartindent = true
vim.opt.encoding = "utf-8"
vim.opt.cindent = true
vim.opt.cinoptions = "g0,t0,(0"

vim.opt.winborder = "rounded"

vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.wrap = true
vim.opt.linebreak = true
vim.opt.title = true
vim.opt.inccommand = "split"
vim.opt.undodir = os.getenv("HOME") .. "/.vim/undodir"
vim.opt.undofile = true

vim.opt.hlsearch = true
vim.opt.incsearch = true
vim.opt.iskeyword:append("-") -- when navigating by w it will consider a-word as one
vim.opt.selection = "inclusive"

vim.opt.shortmess:append("sIca")
vim.opt.cmdheight = 0

vim.opt.updatetime = 50
vim.opt.timeoutlen = 50
vim.opt.redrawtime = 10000
vim.opt.maxmempattern = 20000
vim.opt.termguicolors = true
vim.opt.foldlevelstart = 99
vim.opt.fillchars = { eob = " " }

vim.opt.autoread = true
vim.opt.autowrite = false

vim.api.nvim_create_autocmd("TextYankPost", {
	group = vim.api.nvim_create_augroup("HighlightYank", { clear = true }),
	callback = function()
		vim.hl.on_yank()
	end,
})
vim.api.nvim_create_autocmd({ "FocusGained", "BufEnter", "CursorHold", "CursorHoldI" }, {
	group = vim.api.nvim_create_augroup("AutoReload", { clear = true }),
	callback = function()
		vim.cmd("checktime")
	end,
})

vim.api.nvim_create_autocmd("FileChangedShellPost", {
	group = vim.api.nvim_create_augroup("AutoReloadNotify", { clear = true }),
	callback = function()
		vim.notify("File changed on disk and reloaded", vim.log.levels.WARN)
	end,
})

vim.api.nvim_create_autocmd({ "BufAdd", "BufEnter" }, {
	group = vim.api.nvim_create_augroup("UnlistedScratchBuffers", { clear = true }),
	callback = function(args)
		local buf = args.buf
		local name = vim.api.nvim_buf_get_name(buf)
		local buftype = vim.bo[buf].buftype
		if name == "" or buftype ~= "" then
			vim.bo[buf].buflisted = false
		end
	end,
})

vim.opt.wildignore:append({ ".DS_Store" })
vim.opt.completeopt = "menuone,noselect,noinsert"
vim.diagnostic.config({
	signs = false,
	virtual_text = false,
	underline = true,
	float = true,
})

do
	local mason_bin = vim.fn.stdpath("data") .. "/mason/bin"
	if not vim.env.PATH:find(mason_bin, 1, true) then
		vim.env.PATH = mason_bin .. ":" .. vim.env.PATH
	end
end

vim.filetype.add({
	extension = {
		svelte = "svelte",
		hbs = "handlebars",
		handlebars = "handlebars",
		mustache = "handlebars",
		moustache = "handlebars",
	},
})

vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_node_provider = 0
