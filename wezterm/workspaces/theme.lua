local M = {}

M.palette = { bar = "#000000", divider = "#223022" }

M.schemes = {
	green = { fg = "#77DD77", dim = "#3F7F3F", bg = "#0E180E", focus = "#162616" },
	idle = { fg = "#4F8F4F", dim = "#2E4E2E", bg = "#0B100B", focus = "#121B12" },
	purple = { fg = "#A58BD3", dim = "#6A5A88", bg = "#15111D", focus = "#201A2D" },
	orange = { fg = "#E0955A", dim = "#8E5F3A", bg = "#1C130B", focus = "#2A1C10" },
	red = { fg = "#E06C75", dim = "#8E4A4F", bg = "#1E1012", focus = "#2C1519" },
	grey = { fg = "#8C8C8C", dim = "#555555", bg = "#121212", focus = "#1C1C1C" },
}

local s = M.schemes

local states = {
	starting = s.purple,
	working = s.purple,
	waiting = s.orange,
	message = s.red,
	done = s.green,
	idle = s.idle,
	stopped = s.grey,
}

local kinds = { ok = s.green, busy = s.purple, bad = s.orange, off = s.grey }

local modes = {
	insert = s.purple,
	visual = s.orange,
	["v-line"] = s.orange,
	["v-block"] = s.orange,
	select = s.orange,
	["s-line"] = s.orange,
	replace = s.orange,
	command = s.red,
}

function M.state(word)
	return states[word] or s.green
end

function M.kind(kind)
	return kinds[kind] or s.grey
end

function M.mode(mode)
	return { label = mode, scheme = modes[mode] or s.green }
end

return M
