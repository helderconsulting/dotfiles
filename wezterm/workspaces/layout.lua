local wezterm = require("wezterm")
local log = require("workspaces.store").log
local Workspace = require("workspaces.store").models.Workspace

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

local function split(w, role, pane, opts)
	local ok, made = pcall(pane.split, pane, with(spawn(w, role), opts))
	if not ok then
		log.error("layout.split.failed", { workspace = w.id, role = role, pane = pane:pane_id(), size = opts.size, error = tostring(made) })
		return nil
	end
	w:set_pane(role, made:pane_id())
	return made
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
		local fits = corner and Workspace.fit(size, corner.width, Workspace.sizes.editor.min, Workspace.sizes.sidebar.min)
		if fits then
			split(w, "sidebar", corner.pane, { direction = "Left", size = fits, top_level = corner.height ~= rows })
			panes = info(tab)
		else
			log.warn("layout.no_room", { workspace = w.id, role = "sidebar", want = size, room = corner and corner.width })
		end
	end
	local sidebar = panes[w:pane("sidebar") or -1]
	if missing.conversation and widths.conversation and sidebar then
		local room = sidebar.width - widths.sidebar - 1
		local fits = Workspace.fit(room > 0 and room or widths.conversation, sidebar.width, Workspace.sizes.sidebar.min, Workspace.sizes.conversation.min)
		if fits then
			split(w, "conversation", sidebar.pane, { direction = "Right", size = fits })
		else
			log.warn("layout.no_room", { workspace = w.id, role = "conversation", room = sidebar.width })
		end
	end
	if missing.docker and w:wants("docker") then
		split(w, "docker", editor.pane, { direction = "Bottom", size = w.docker_share(rows) })
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
