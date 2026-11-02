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
	ReviewSent = { fg = palette.orange, italic = true },
	ReviewSentSign = { fg = palette.orange, bold = true },
	ReviewResolved = { fg = palette.dim, italic = true },
	ReviewResolvedSign = { fg = palette.green, bold = true },
	ReviewReady = { fg = palette.bright, bold = true },
	ReviewStatus = { fg = "#6A6280" },
	InfoFloat = { bg = "#0C140C" },
	-- Docker view (configs/docker.lua): tabs like the bar's entries, sections like fzf-lua's list
	-- (packs/fzf.lua: fg+ on bg+, bold like fzf's current line), container status in the agent
	-- states' colors.
	DockerTab = { fg = palette.green },
	DockerTabOff = { fg = palette.dim },
	DockerTabCurrent = { fg = palette.bright, bg = "#162616", bold = true },
	DockerWord = { fg = palette.dim },
	DockerWordBusy = { fg = palette.purple },
	DockerWordBad = { fg = palette.orange },
	DockerMenu = { fg = palette.green },
	DockerMenuSelected = { fg = palette.bright, bg = "#0F2A0F", bold = true },
	-- Cards (configs/cards.lua) in their status's colors; the cursor takes the current one's background.
	CardCursor = { fg = "#0F2A0F", bg = "#0F2A0F" },
	CardMarked = { fg = palette.purple },
	CardMarkedBg = { bg = "#15111D" },
	-- Window separators match WezTerm's split lines and agent bar edges.
	WinSeparator = { fg = "#223022" },
}
for group, spec in pairs(highlights) do
	vim.api.nvim_set_hl(0, group, spec)
end
for kind, c in pairs({
	Ok = { fg = palette.green, bright = palette.bright, dim = palette.dim, bg = "#0F2A0F", inactive = "#0B1A0B" },
	Busy = { fg = palette.purple, bright = "#C0A8EC", dim = "#6A5A88", bg = "#201A2D", inactive = "#15111D" },
	Bad = { fg = palette.orange, bright = "#F2AE78", dim = "#8E5F3A", bg = "#2A1C10", inactive = "#1C130B" },
	Off = { fg = "#8C8C8C", bright = "#B4B4B4", dim = "#555555", bg = "#1C1C1C", inactive = "#121212" },
}) do
	vim.api.nvim_set_hl(0, "Card" .. kind, { fg = c.fg })
	vim.api.nvim_set_hl(0, "Card" .. kind .. "Current", { fg = c.bright, bold = true })
	vim.api.nvim_set_hl(0, "Card" .. kind .. "Detail", { fg = c.dim })
	vim.api.nvim_set_hl(0, "Card" .. kind .. "Bg", { bg = c.bg })
	vim.api.nvim_set_hl(0, "Card" .. kind .. "BgInactive", { bg = c.inactive })
end
