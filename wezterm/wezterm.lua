local wezterm = require("wezterm")
local config = wezterm.config_builder()

config.font = wezterm.font("JetBrains Mono")
config.color_scheme = "Tokyo Night"
config.enable_tab_bar = false
config.window_decorations = "RESIZE"
config.window_padding = {
	left = 42,
	right = 42,
	top = 42,
	bottom = 42,
}

config.native_macos_fullscreen_mode = true

local function navigate(direction, fallback_direction)
	return wezterm.action_callback(function(win, pane)
		local num_panes = #win:active_tab():panes()
		local pane_direction = num_panes == 2 and fallback_direction or direction
		win:perform_action({ ActivatePaneDirection = pane_direction }, pane)
	end)
end

config.keys = {
	{ mods = "CTRL|ALT", key = "d", action = wezterm.action.CloseCurrentPane({ confirm = true }) },
	{ mods = "CTRL|ALT", key = "h", action = wezterm.action.SplitHorizontal({ domain = "CurrentPaneDomain" }) },
	{ mods = "CTRL|ALT", key = "v", action = wezterm.action.SplitVertical({ domain = "CurrentPaneDomain" }) },
	{ mods = "CTRL|ALT", key = "n", action = navigate("Left", "Prev") },
	{ mods = "CTRL|ALT", key = "i", action = navigate("Right", "Next") },
	{ mods = "CTRL|ALT", key = "e", action = navigate("Up", "Prev") },
	{ mods = "CTRL|ALT", key = "o", action = navigate("Down", "Next") },
}

return config
