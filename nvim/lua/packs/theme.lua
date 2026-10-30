vim.pack.add({
	"https://github.com/metalelf0/black-metal-theme-neovim",
})

local theme = require("black-metal")
theme.setup({
	theme = "burzum",
	variant = "dark",
	colors = {
		string = "#77DD77",
	},
})

theme.load()

-- Same accents as the WezTerm agent bar: green adds, orange deletes, purple changes and review notes.
local palette = {
	green = "#55BB55",
	bright = "#77DD77",
	dim = "#3F6F3F",
	purple = "#A58BD3",
	orange = "#E0955A",
}
local highlights = {
	DiffAdd = { bg = "#0F2412" },
	DiffDelete = { bg = "#2A1A10" },
	DiffChange = { bg = "#17131F" },
	DiffText = { bg = "#2C2240" },
	CodeDiffFiller = { fg = "#1A221A" },
	CodeDiffExplorerSelected = { bg = "#18131F", fg = palette.bright, bold = true },
	CodeDiffExplorerTreeGroup = { fg = palette.dim },
	CodeDiffStatusAdded = { fg = palette.green },
	CodeDiffStatusModified = { fg = palette.purple },
	CodeDiffStatusDeleted = { fg = palette.orange },
	CodeDiffStatusRenamed = { fg = palette.purple },
	CodeDiffStatusUntracked = { fg = palette.dim },
	CodeDiffStatusConflict = { fg = palette.orange, bold = true },
	ReviewNote = { fg = palette.purple, italic = true },
	ReviewNoteSign = { fg = palette.purple, bold = true },
	ReviewNoteLine = { bg = "#120F18" },
	ReviewNoteTitle = { fg = palette.purple, bg = "#120F18", bold = true },
	ReviewNoteHint = { fg = "#505050", bg = "#120F18" },
	InfoFloat = { bg = "#0C140C" },
	-- Window separators match WezTerm's split lines and agent bar edges.
	WinSeparator = { fg = "#223022" },
}
for group, spec in pairs(highlights) do
	vim.api.nvim_set_hl(0, group, spec)
end
