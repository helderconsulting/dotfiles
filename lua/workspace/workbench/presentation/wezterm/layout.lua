local wezterm = require("wezterm")
local state = require("workspace.workbench.presentation.wezterm.state")
local log = state.log

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
	local by_id = {}
	for _, p in ipairs(tab:panes_with_info()) do
		by_id[p.pane:pane_id()] = p
	end
	local size = tab:get_size()
	return by_id, size.cols, size.rows
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

function M.ensure(tab, w, keep_closed)
	local workbench = state.workbench()
	local limits = workbench:limits()
	local panes, total, rows = info(tab)
	local focused = tab:active_pane()
	local function alive(id)
		return panes[id] ~= nil
	end
	local missing = {}
	for _, role in ipairs(workbench:missing_roles(w.mode, w.panes, alive, keep_closed)) do
		missing[role] = true
	end
	local widths = workbench:widths(w.mode, total)
	log.info("layout.ensure", { workspace = w.id, total = total, widths = widths, missing = missing })
	local editor = panes[w:pane("editor")]
	if not editor then
		return
	end
	if missing.sidebar and widths.sidebar then
		local size = widths.sidebar + ((missing.conversation and widths.conversation) and (widths.conversation + 1) or 0)
		local fits = workbench:fit(size, total, limits.editor_min, limits.sidebar_min)
		if fits then
			split(w, "sidebar", editor.pane, { direction = "Left", size = fits, top_level = true })
			panes = info(tab)
		else
			log.warn("layout.no_room", { workspace = w.id, role = "sidebar", want = size, room = total })
		end
	end
	local sidebar = panes[w:pane("sidebar") or -1]
	if missing.conversation and widths.conversation and sidebar then
		local room = sidebar.width - widths.sidebar - 1
		local fits = workbench:fit(room > 0 and room or widths.conversation, sidebar.width, limits.sidebar_min, limits.conversation_min)
		if fits then
			split(w, "conversation", sidebar.pane, { direction = "Right", size = fits })
		else
			local beside = workbench:fit(widths.conversation, editor.width, limits.editor_min, limits.conversation_min)
			if beside then
				split(w, "conversation", editor.pane, { direction = "Left", size = beside })
			else
				log.warn("layout.no_room", { workspace = w.id, role = "conversation", room = sidebar.width })
			end
		end
	end
	if missing.docker then
		local size = workbench:docker_rows(editor.height, rows)
		if size then
			split(w, "docker", editor.pane, { direction = "Bottom", size = size })
		else
			log.warn("layout.no_room", { workspace = w.id, role = "docker", room = editor.height })
		end
	end
	if keep_closed and focused then
		focused:activate()
	else
		editor.pane:activate()
	end
end

function M.grow(tab, w)
	local ok, err = pcall(M.ensure, tab, w, true)
	if not ok then
		log.error("layout.grow_failed", { workspace = w.id, error = tostring(err) })
	end
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
	local widths = state.workbench():widths(w.mode, total)
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
