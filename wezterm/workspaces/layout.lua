local wezterm = require("wezterm")
local log = require("workspaces.store").log

local M = {}

local shell = os.getenv("SHELL") or "zsh"

function M.command(program, cwd, keep)
	local cd = cwd and "cd " .. wezterm.shell_quote_arg(cwd) .. " && " or ""
	return { shell, "-lc", cd .. program .. (keep and ("; exec " .. shell .. " -l") or "") }
end

local function spawn(w, role)
	return {
		cwd = w.root,
		args = M.command("nvim", w.root, role == "editor"),
		set_environment_variables = { WORKSPACE_ROLE = role, WORKSPACE_ID = w.id },
	}
end

local function with(opts, extra)
	for k, v in pairs(extra) do
		opts[k] = v
	end
	return opts
end

function M.create(mux_window, w)
	local tab, editor = mux_window:spawn_tab(spawn(w, "editor"))
	w.tab, w.window = tab:tab_id(), mux_window:window_id()
	w:set_pane("editor", editor:pane_id())
	M.ensure(tab, w)
	return tab
end

local function info(tab)
	local by_id, total, rows = {}, 0, 0
	for _, p in ipairs(tab:panes_with_info()) do
		by_id[p.pane:pane_id()] = p
		total = math.max(total, p.left + p.width)
		rows = math.max(rows, p.top + p.height)
	end
	return by_id, total, rows
end

function M.ensure(tab, w)
	local panes, total, rows = info(tab)
	local function alive(id)
		return panes[id] ~= nil
	end
	local missing = {}
	for _, role in ipairs(w:missing(alive)) do
		missing[role] = true
	end
	local widths = w:widths(total)
	log.info("layout.ensure", { workspace = w.id, total = total, widths = widths, missing = missing })
	local editor = panes[w:pane("editor")]
	if not editor then
		return
	end
	if missing.sidebar and widths.sidebar then
		local size = widths.sidebar + ((missing.conversation and widths.conversation) and (widths.conversation + 1) or 0)
		local corner
		for _, p in pairs(panes) do
			corner = (p.left == 0 and p.top == 0) and p or corner
		end
		local sidebar = corner.pane:split(with(spawn(w, "sidebar"), { direction = "Left", size = size, top_level = corner.height ~= rows }))
		w:set_pane("sidebar", sidebar:pane_id())
		panes = info(tab)
	end
	local sidebar = panes[w:pane("sidebar") or -1]
	if missing.conversation and widths.conversation and sidebar then
		local room = sidebar.width - widths.sidebar - 1
		local conversation = sidebar.pane:split(with(spawn(w, "conversation"), { direction = "Right", size = room > 0 and room or widths.conversation }))
		w:set_pane("conversation", conversation:pane_id())
	end
	if missing.docker and w:wants("docker") then
		local docker = editor.pane:split(with(spawn(w, "docker"), { direction = "Bottom", size = w.docker_share(rows) }))
		w:set_pane("docker", docker:pane_id())
	end
	editor.pane:activate()
end

local cli = wezterm.executable_dir .. "/wezterm"

local function adjust(pane, delta)
	log.info("layout.adjust", { pane = pane:pane_id(), delta = delta })
	if delta == 0 then
		return
	end
	pane:activate()
	wezterm.run_child_process({ cli, "cli", "adjust-pane-size", "--pane-id", tostring(pane:pane_id()), "--amount", tostring(math.abs(delta)), delta > 0 and "Right" or "Left" })
end

function M.apply(tab, w)
	local panes, total = info(tab)
	local widths = w:widths(total)
	log.info("layout.apply", { workspace = w.id, total = total, widths = widths })
	local active = tab:active_pane()
	local sidebar = panes[w:pane("sidebar") or -1]
	if sidebar and widths.sidebar then
		adjust(sidebar.pane, widths.sidebar - sidebar.width)
		panes = info(tab)
	end
	local conversation = panes[w:pane("conversation") or -1]
	local editor = panes[w:pane("editor") or -1]
	if conversation and editor and widths.conversation then
		adjust(editor.pane, widths.conversation - conversation.width)
	end
	local after = info(tab)
	log.info("layout.applied", {
		workspace = w.id,
		sidebar = after[w:pane("sidebar") or -1] and after[w:pane("sidebar")].width,
		conversation = after[w:pane("conversation") or -1] and after[w:pane("conversation")].width,
		editor = after[w:pane("editor") or -1] and after[w:pane("editor")].width,
	})
	if active then
		active:activate()
	end
end

return M
