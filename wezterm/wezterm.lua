local wezterm = require("wezterm")
local config = wezterm.config_builder()

config.font = wezterm.font("JetBrains Mono")
config.font_size = 18
config.color_scheme = "green"
config.enable_tab_bar = false
config.window_decorations = "RESIZE"
config.window_padding = {
	left = 0,
	right = 0,
	top = 0,
	bottom = 0,
}

config.tab_bar_at_bottom = false
config.hide_tab_bar_if_only_one_tab = true

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

-- Copy mode works like Neovim's normal mode for a pane's text: v / V select, y copies, x copies too
-- (terminal text can't be cut), p pastes. ALT v enters it with a selection started, like v in
-- Neovim (physical key, so Option v on macOS doesn't turn into √); CTRL|SHIFT x without one.
local copy_mode = wezterm.gui.default_key_tables().copy_mode
local close = wezterm.action.Multiple({
	wezterm.action.ScrollToBottom,
	wezterm.action.CopyMode("Close"),
})
table.insert(copy_mode, {
	key = "x",
	mods = "NONE",
	action = wezterm.action.Multiple({ wezterm.action.CopyTo("ClipboardAndPrimarySelection"), close }),
})
table.insert(copy_mode, {
	key = "p",
	mods = "NONE",
	action = wezterm.action.Multiple({ close, wezterm.action.PasteFrom("Clipboard") }),
})
config.key_tables = { copy_mode = copy_mode }
table.insert(config.keys, {
	mods = "ALT",
	key = "phys:V",
	action = wezterm.action.Multiple({
		wezterm.action.ActivateCopyMode,
		wezterm.action.CopyMode({ SetSelectionMode = "Cell" }),
	}),
})

require("agents").apply(config)

return config
