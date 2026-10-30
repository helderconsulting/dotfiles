-- ALT arrows move focus across Neovim windows, WezTerm panes and AeroSpace windows as one grid.
-- AeroSpace owns the keys (bin/nav); while WezTerm is focused the request arrives here through the
-- window title (see agents.lua). Neovim moves between its own windows and at its edge asks WezTerm
-- to continue through the nav user var (nvim/lua/configs/keymaps.lua). Moves go to the next pane,
-- or at WezTerm's edge to AeroSpace (bin/aerospace-edge).
local wezterm = require("wezterm")

local M = {}

local edge = wezterm.config_dir .. "/bin/aerospace-edge"

-- Move from pane (the focused one) in direction ("Left", "Right", "Up", "Down").
function M.go(pane, direction)
	local neighbor = pane:tab():get_pane_direction(direction)
	if neighbor then
		neighbor:activate()
	else
		wezterm.background_child_process({ edge, direction:lower() })
	end
end

local function is_nvim(pane)
	return (pane:get_foreground_process_name() or ""):find("n?vim$") ~= nil
end

-- An ALT arrow from bin/nav while WezTerm is focused ("left", "right", "up", "down"). Neovim gets the
-- key itself and hands back at its edge through the nav user var.
function M.step(window, direction)
	direction = direction:sub(1, 1):upper() .. direction:sub(2)
	local pane = window:active_pane()
	if is_nvim(pane) then
		window:perform_action({ SendKey = { key = direction .. "Arrow", mods = "ALT" } }, pane)
	else
		M.go(pane, direction)
	end
end

return M
