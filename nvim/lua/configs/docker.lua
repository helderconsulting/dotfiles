-- Docker view for the pane under Neovim that CTRL|ALT w opens (wezterm/agents.lua runs nvim +Docker),
-- in its own Neovim. Laid out like the CodeDiff view: the sections (containers, images, volumes) on
-- the right, the current entry's logs or details on the left. The section's entries are tabs that
-- act like buffers: the WezTerm bar shows them in this pane's entry, labeled with the current one's
-- status (a container's state, whether an image or volume is in use), and ALT left and right page
-- through them. ALT up and down go through the sections; past the ends
-- both move on to the next WezTerm pane like the rest of the ALT arrow grid (configs/keymaps.lua).
-- A count moves that many like 5j does (5 ALT down), stopping at the end instead. gg and G go to the
-- first and last entry, 12G to the twelfth.
-- The actions sit under the leader, where which-key shows only the current section's (packs/whichkey.lua).
-- Every section uses the same keys for the same kind of action, done to whatever its entry is:
--   s  start or stop (a container, script or VM, a desktop or the VPN connection, a workspace, an agent)
--   r  restart       o  open or go to (in the browser, the workspace, the agent)
--   e  shell into it i  toggle details and inspect
--   y  copy          d  delete or remove
--   a  add           n  rename            f  find in this section      -  close the view
-- plus the few a section has to itself (a desktop's c settings and p password, the VPN's x exit node).
-- Below the docker sections sit the project's package.json scripts (configs/scripts.lua), the lima
-- VMs (configs/vms.lua), the remote desktops opened with FreeRDP (configs/desktops.lua), the devices
-- on the Tailscale VPN (configs/tailscale.lua) and the ports this Mac listens on (configs/ports.lua),
-- then the projects' WezTerm workspaces (configs/workspaces.lua) and the Claude sessions, running and
-- earlier (configs/agents.lua).
local M = {}

local vms = require("configs.vms")
local desktops = require("configs.desktops")
local tailscale = require("configs.tailscale")
local ports = require("configs.ports")
local scripts = require("configs.scripts")
local workspaces = require("configs.workspaces")
local agents = require("configs.agents")

local sections = { "containers", "images", "volumes", "scripts", "vms", "desktops", "vpn devices", "ports", "workspaces", "agents" }

local state = {
	section = 1,
	entries = {
		containers = {},
		images = {},
		volumes = {},
		vms = {},
		desktops = {},
		["vpn devices"] = {},
		ports = {},
		scripts = {},
		workspaces = {},
		agents = {},
	},
	-- The id of the current tab per section, kept while the lists refresh.
	current = {},
	down = false,
	-- The project folder when the containers are the project's, nil when they are all of them.
	project = nil,
	-- Content of the current tab: "logs" or "inspect" for containers and VMs.
	mode = "logs",
}

local main_win, main_buf, menu_win, menu_buf

-- The menu is as wide as CodeDiff's explorer (packs/git.lua), so the two side panels line up, and
-- the view's entry in the WezTerm bar takes the same width plus the split line (report).
local function menu_width()
	local ok, config = pcall(require, "codediff.config")
	local width = ok and config.options and config.options.explorer and config.options.explorer.width
	return type(width) == "number" and width or 35
end
local ns = vim.api.nvim_create_namespace("docker")

-- A container's status word from docker's state and status text ("Up 3 minutes (healthy)",
-- "Exited (1) 2 seconds ago"), and how it reads: ok runs, busy is getting there, bad needs a look,
-- off is stopped on purpose.
local function container_status(st, status)
	if st == "running" then
		if status:find("(unhealthy)", 1, true) then
			return "unhealthy", "bad"
		elseif status:find("health: starting", 1, true) then
			return "starting", "busy"
		elseif status:find("(healthy)", 1, true) then
			return "healthy", "ok"
		end
		return "up", "ok"
	elseif st == "exited" then
		local code = status:match("^Exited %((%d+)%)")
		if code and code ~= "0" then
			return "exited " .. code, "bad"
		end
		return "exited", "off"
	elseif st == "restarting" or st == "removing" then
		return st, "busy"
	elseif st == "dead" then
		return "dead", "bad"
	end
	return st, "off"
end

local lists = {
	containers = {
		docker = true,
		cmd = {
			"docker",
			"ps",
			"--all",
			"--no-trunc",
			"--format",
			'{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Label "com.docker.compose.service"}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Image}}\t{{.Mounts}}\t{{.Ports}}',
		},
		-- The project's containers (compose file in the cwd or below it) by service, or all of them
		-- by name when the project has none. Every container's image and volumes count as in use.
		parse = function(lines)
			local cwd = vim.fn.getcwd()
			local project, all = {}, {}
			state.used = {}
			for _, line in ipairs(lines) do
				local id, name, st, status, service, dir, image, mounts, ports_text = unpack(vim.split(line, "\t"))
				-- The first host port it publishes ("0.0.0.0:8080->80/tcp"), for <leader>o.
				local port = (ports_text or ""):match(":(%d+)%->")
				if id and id ~= "" then
					state.used[image or ""] = true
					for _, mount in ipairs(vim.split(mounts or "", ",")) do
						state.used[mount] = true
					end
					local word, kind = container_status(st, status or "")
					table.insert(all, { id = id, name = name, container = name, port = port, word = word, kind = kind })
					if dir and dir ~= "" and vim.fs.relpath(cwd, dir) then
						table.insert(project, {
							id = id,
							name = service ~= "" and service or name,
							container = name,
							port = port,
							word = word,
							kind = kind,
						})
					end
				end
			end
			state.project = #project > 0 and vim.fs.basename(cwd) or nil
			return #project > 0 and project or all
		end,
	},
	images = {
		docker = true,
		cmd = { "docker", "image", "ls", "--format", "{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}" },
		parse = function(lines)
			local list = {}
			for _, line in ipairs(lines) do
				local id, repo, tag, size = unpack(vim.split(line, "\t"))
				if id and id ~= "" then
					local name = repo == "<none>" and id or tag == "latest" and repo or repo .. ":" .. tag
					-- Containers name their image as it was asked for, with or without the latest tag.
					local refs = { id, name, repo .. ":" .. tag }
					table.insert(list, { id = id, name = name, refs = refs })
				end
			end
			return list
		end,
	},
	volumes = {
		docker = true,
		cmd = { "docker", "volume", "ls", "--format", "{{.Name}}" },
		parse = function(lines)
			local list = {}
			for _, name in ipairs(lines) do
				if name ~= "" then
					table.insert(list, { id = name, name = name, refs = { name } })
				end
			end
			return list
		end,
	},
	vms = vms,
	desktops = desktops,
	["vpn devices"] = tailscale,
	ports = ports,
	scripts = scripts,
	workspaces = workspaces,
	agents = agents,
}

local function section_name()
	return sections[state.section]
end

-- The engine being down only matters to the docker sections.
local function docker_down()
	return state.down and lists[section_name()].docker == true
end

local function current_entry()
	local name = section_name()
	for i, e in ipairs(state.entries[name]) do
		if e.id == state.current[name] then
			return e, i
		end
	end
end

-- Bar entry ---------------------------------------------------------------------------------------

local last_report
local function report()
	if not vim.env.WEZTERM_PANE then
		return
	end
	local tabs = {}
	for _, e in ipairs(state.entries[section_name()]) do
		table.insert(tabs, { name = e.name, word = e.word, kind = e.kind, current = e.id == state.current[section_name()] })
	end
	local info = {
		section = section_name(),
		project = lists[section_name()].docker and (state.project or "all") or section_name(),
		down = docker_down(),
		tabs = tabs,
		width = menu_width() + 1,
	}
	-- A section with a state of its own (the VPN's) labels the bar with it on every tab, and the
	-- current entry's status goes where the project would.
	local section = lists[section_name()]
	-- A section about a place of its own (the scripts' project) names it where the project would.
	if section.place then
		info.project = section.place()
	end
	if section.badge then
		local word, kind = section.badge()
		local entry = current_entry()
		info.badge = { word = word, kind = kind }
		info.project = entry and not entry.self and entry.word or ""
	end
	local payload = vim.json.encode(info)
	if payload ~= last_report then
		last_report = payload
		vim.api.nvim_ui_send(("\27]1337;SetUserVar=docker_view=%s\7"):format(vim.base64.encode(payload)))
	end
end

-- Section menu ------------------------------------------------------------------------------------

local function render_menu()
	if not (menu_buf and vim.api.nvim_buf_is_valid(menu_buf)) then
		return
	end
	local width = menu_win and vim.api.nvim_win_is_valid(menu_win) and vim.api.nvim_win_get_width(menu_win)
		or menu_width()
	local lines = {}
	for _, name in ipairs(sections) do
		local count = tostring(#state.entries[name])
		-- Two columns in front, where fzf keeps its pointer and marker.
		table.insert(lines, "  " .. name .. string.rep(" ", math.max(width - #name - #count - 3, 1)) .. count)
	end
	vim.bo[menu_buf].modifiable = true
	vim.api.nvim_buf_set_lines(menu_buf, 0, -1, false, lines)
	vim.bo[menu_buf].modifiable = false
	vim.api.nvim_buf_clear_namespace(menu_buf, ns, 0, -1)
	for i, line in ipairs(lines) do
		local selected = i == state.section
		vim.api.nvim_buf_set_extmark(menu_buf, ns, i - 1, 0, {
			end_col = #line,
			hl_group = selected and "DockerMenuSelected" or "DockerMenu",
			line_hl_group = selected and "DockerMenuSelected" or nil,
		})
		local count_col = #line - #tostring(#state.entries[sections[i]])
		vim.api.nvim_buf_set_extmark(menu_buf, ns, i - 1, count_col, {
			end_col = #line,
			hl_group = selected and "DockerMenuSelected" or "DockerWord",
			priority = 4200,
		})
	end
end

-- Content -----------------------------------------------------------------------------------------

local job, generation = nil, 0
local shown -- section and id the content is for

local function set_content(lines)
	vim.bo[main_buf].modifiable = true
	vim.api.nvim_buf_set_lines(main_buf, 0, -1, false, lines)
	vim.bo[main_buf].modifiable = false
end

-- Append output, following it while the cursor sits on the last line.
local function append(lines)
	if not vim.api.nvim_buf_is_valid(main_buf) then
		return
	end
	local count = vim.api.nvim_buf_line_count(main_buf)
	local empty = count == 1 and vim.api.nvim_buf_get_lines(main_buf, 0, 1, false)[1] == ""
	local follow = vim.api.nvim_win_is_valid(main_win) and vim.api.nvim_win_get_cursor(main_win)[1] >= count
	vim.bo[main_buf].modifiable = true
	vim.api.nvim_buf_set_lines(main_buf, empty and 0 or -1, -1, false, lines)
	vim.bo[main_buf].modifiable = false
	if follow then
		vim.api.nvim_win_set_cursor(main_win, { vim.api.nvim_buf_line_count(main_buf), 0 })
	end
end

-- Run cmd and put its output (stdout and stderr, colors stripped) in the content window as it
-- arrives. Output of an earlier run is dropped once another one starts.
local function stream(cmd)
	generation = generation + 1
	local gen, partial = generation, { stdout = "", stderr = "" }
	local function on(kind)
		return function(_, data)
			if not data then
				return
			end
			local text = (partial[kind] .. data):gsub("\27%[[%d;?]*[A-Za-z]", ""):gsub("\r", "")
			local lines = vim.split(text, "\n")
			partial[kind] = table.remove(lines)
			if #lines > 0 then
				vim.schedule(function()
					if gen == generation then
						append(lines)
					end
				end)
			end
		end
	end
	job = vim.system(cmd, { stdout = on("stdout"), stderr = on("stderr") })
end

-- Show buf in the content window: a section's terminal (configs/scripts.lua), with bar on top, or
-- the view's own content without one.
local function display(buf, bar)
	if not (main_win and vim.api.nvim_win_is_valid(main_win)) then
		return
	end
	-- Only a different buffer swaps (and follows its end): a new status line mustn't take the cursor
	-- out of the terminal or away from what it scrolled to.
	if vim.api.nvim_win_get_buf(main_win) ~= buf then
		vim.api.nvim_win_set_buf(main_win, buf)
		if bar then
			vim.api.nvim_win_set_cursor(main_win, { vim.api.nvim_buf_line_count(buf), 0 })
		end
	end
	vim.wo[main_win].winbar = bar and bar:gsub("%%", "%%%%") or ""
end

local function show()
	local name, entry = section_name(), current_entry()
	-- An entry's view_key changes when its content does (a script started again in a new terminal).
	local key = entry and (name .. ":" .. entry.id .. ":" .. state.mode .. ":" .. (entry.view_key or ""))
		or (name .. (docker_down() and ":down" or ":none"))
	if key == shown then
		return
	end
	shown = key
	if job then
		job:kill(15)
		job = nil
	end
	generation = generation + 1
	local term
	set_content({})
	if docker_down() then
		set_content({ "", " the docker engine isn't running", " start it with: brew services start colima" })
	elseif not entry and name == "desktops" then
		set_content({
			"",
			" no desktops",
			" add one with <leader>a, or export PCs from Windows App into",
			" " .. vim.fn.fnamemodify(desktops.dir, ":~") .. " (<leader>o opens it)",
		})
	elseif not entry then
		set_content({ "", " no " .. name })
	elseif lists[name].show then
		local lines, cmd
		lines, cmd, term = lists[name].show(entry, state.mode)
		set_content(lines)
		if cmd and not term then
			stream(cmd)
		end
	elseif name == "containers" and state.mode == "logs" then
		stream({ "docker", "logs", "--tail", "500", "--follow", entry.id })
	elseif name == "containers" then
		stream({ "docker", "container", "inspect", entry.id })
	elseif name == "images" then
		stream({ "docker", "image", "history", "--format", "{{.CreatedSince}}\t{{.Size}}\t{{.CreatedBy}}", entry.id })
	else
		stream({ "docker", "volume", "inspect", entry.id })
	end
	display(term and term.buf or main_buf, term and term.bar)
end

local set_actions

local function redraw()
	render_menu()
	set_actions()
	show()
	report()
end

-- Refresh ----------------------------------------------------------------------------------------

-- A name's sort key: case left out and numbers padded, so vmix 2 comes before vmix 10.
local function natural(name)
	return (name:lower():gsub("%d+", function(n)
		return ("%012d"):format(tonumber(n))
	end))
end

local function refresh()
	local pending = #sections
	local down = false
	for _, name in ipairs(sections) do
		local function finish(list)
			if not list then
				down = true
				state.entries[name] = {}
			else
				-- By name, after the entries a section puts first (tailscale's own Mac).
				table.sort(list, function(a, b)
					if (a.order or 1) ~= (b.order or 1) then
						return (a.order or 1) < (b.order or 1)
					end
					return natural(a.name) < natural(b.name)
				end)
				state.entries[name] = list
			end
			-- Keep the current tab; fall back to the first when it is gone.
			local keep = false
			for _, e in ipairs(state.entries[name]) do
				keep = keep or e.id == state.current[name]
			end
			if not keep then
				state.current[name] = state.entries[name][1] and state.entries[name][1].id
			end
			pending = pending - 1
			if pending == 0 then
				state.down = down
				-- Images and volumes are in use when a container has them (lists.containers).
				for _, section in ipairs({ "images", "volumes" }) do
					for _, e in ipairs(state.entries[section]) do
						local used = false
						for _, ref in ipairs(e.refs) do
							used = used or (state.used or {})[ref] == true
						end
						e.word, e.kind = used and "in use" or "unused", used and "ok" or "off"
					end
				end
				redraw()
			end
		end
		if lists[name].fetch then
			lists[name].fetch(finish)
		else
			vim.system(lists[name].cmd, { text = true }, function(res)
				vim.schedule(function()
					finish(res.code == 0 and lists[name].parse(vim.split(res.stdout, "\n", { trimempty = true })) or nil)
				end)
			end)
		end
	end
end

-- Navigation -------------------------------------------------------------------------------------

-- Past the ends hand the move to WezTerm, like configs/keymaps.lua; the clock makes every request a
-- change for WezTerm's user-var-changed event.
local function hand_off(direction)
	if vim.env.WEZTERM_PANE then
		local value = vim.base64.encode(direction .. ":" .. vim.uv.hrtime())
		vim.api.nvim_ui_send(("\27]1337;SetUserVar=nav=%s\7"):format(value))
	end
end

local function step_tab(delta, direction)
	local list = state.entries[section_name()]
	local _, index = current_entry()
	local target = list[(index or 0) + delta * vim.v.count1]
	if vim.v.count > 0 then
		target = target or list[delta > 0 and #list or 1]
	end
	if not target then
		return hand_off(direction)
	end
	state.current[section_name()] = target.id
	state.mode = "logs"
	redraw()
end

-- gg and G go to the section's first and last entry, and with a count to that entry (12G), the way
-- they go to lines.
local function go_tab(first)
	local list = state.entries[section_name()]
	local target = list[vim.v.count > 0 and math.min(vim.v.count, #list) or first and 1 or #list]
	if target then
		state.current[section_name()] = target.id
		state.mode = "logs"
		redraw()
	end
end

local function step_section(delta, direction)
	local target = state.section + delta * vim.v.count1
	if vim.v.count > 0 then
		target = math.max(1, math.min(#sections, target))
	end
	if not sections[target] then
		return hand_off(direction)
	end
	state.section = target
	state.mode = "logs"
	redraw()
end

-- Actions ----------------------------------------------------------------------------------------

-- What the sections' actions get to work with besides their entry.
local view = {}

-- Run cmd, show its error if it fails, and refresh the lists either way. opts.done runs first.
function view.run(cmd, opts)
	opts = opts or {}
	vim.system(cmd, { text = true, env = opts.env }, function(res)
		vim.schedule(function()
			if opts.done then
				opts.done(res)
			end
			if res.code ~= 0 then
				vim.notify(vim.trim(res.stderr ~= "" and res.stderr or res.stdout), vim.log.levels.ERROR)
			end
			refresh()
		end)
	end)
end

-- Run cmd in a WezTerm pane to the right of the view.
function view.split(cmd)
	vim.system(
		vim.list_extend({ "wezterm", "cli", "split-pane", "--pane-id", vim.env.WEZTERM_PANE, "--right", "--" }, cmd)
	)
end

function view.refresh()
	refresh()
end

-- Ask before something that can't be undone; an action run on several picked entries at once
-- (find) was asked about once for all of them.
function view.confirm(question)
	return view.batch or vim.fn.confirm(question, "&yes\n&no", 2) == 1
end

function view.toggle_mode()
	state.mode = state.mode == "logs" and "inspect" or "logs"
	redraw()
end

-- Make the entry with this id the current tab, once it shows up in the list.
function view.select(id)
	state.current[section_name()] = id
	refresh()
end

local function remove(kind)
	return {
		"<leader>d",
		function(e, view)
			if view.confirm("remove " .. e.name .. "?") then
				view.run({ "docker", kind, "rm", e.id })
			end
		end,
		"remove " .. kind,
	}
end

-- Each section's actions get its current entry and the view; the ones marked always also run on an
-- empty section.
local actions = {
	containers = {
		{
			"<leader>s",
			function(e)
				view.run({ "docker", e.kind == "off" and "start" or "stop", e.id })
			end,
			"start or stop container",
		},
		{
			"<leader>r",
			function(e)
				view.run({ "docker", "restart", e.id })
			end,
			"restart container",
		},
		{
			"<leader>o",
			function(e)
				if not e.port then
					return vim.notify(e.name .. " publishes no port", vim.log.levels.WARN)
				end
				vim.ui.open("http://localhost:" .. e.port)
			end,
			"open in browser",
		},
		{
			"<leader>y",
			function(e)
				vim.fn.setreg("+", e.container)
				vim.notify("copied " .. e.container)
			end,
			"copy name",
		},
		{
			"<leader>e",
			function(e)
				view.split({ "docker", "exec", "-it", e.id, "sh" })
			end,
			"shell in container",
		},
		{
			"<leader>i",
			function()
				view.toggle_mode()
			end,
			"toggle logs and inspect",
		},
		remove("container"),
	},
	images = { remove("image") },
	volumes = { remove("volume") },
	vms = vms.actions,
	desktops = desktops.actions,
	["vpn devices"] = tailscale.actions,
	ports = ports.actions,
	scripts = scripts.actions,
	workspaces = workspaces.actions,
	agents = agents.actions,
}

-- Like <leader>- on the diff view: closes the whole view, and with it the pane, since WezTerm runs it
-- without a shell to fall back to.
local close = {
	"<leader>-",
	function()
		vim.cmd("qa")
	end,
	"close docker view",
	always = true,
}

-- Pick entries of the current section with fzf-lua, filtering on its status, name, and host or
-- address, colored like the bar's labels. Enter goes to a workspace or agent (starting or resuming
-- it), and elsewhere makes the pick the current tab. Tab marks several
-- (ctrl-a all of them), and CTRL with an action's key runs that action on every marked entry, asking
-- once for all of them: ctrl-d deletes them, ctrl-s starts or stops them. CTRL, not ALT: Option with
-- a letter types a character on macOS (∂ for d). Actions that ask for input,
-- work without an entry (add), or only make sense for one (rename, a shell, details, going to a
-- workspace or agent) stay single.
local kind_colors = { ok = "#77DD77", busy = "#A58BD3", bad = "#E0955A", off = "#8C8C8C", detail = "#3F6F3F" }
local single = {
	["<leader>n"] = true,
	["<leader>c"] = true,
	["<leader>p"] = true,
	["<leader>e"] = true,
	["<leader>i"] = true,
}

local find = {
	"<leader>f",
	function()
		local name = section_name()
		local list = state.entries[name]
		if #list == 0 then
			return
		end
		require("packs.fzf")
		local fzf = require("fzf-lua")
		local utils = require("fzf-lua.utils")
		local lines, by_line, width = {}, {}, 0
		for _, e in ipairs(list) do
			width = math.max(width, vim.fn.strdisplaywidth(e.name))
		end
		for _, e in ipairs(list) do
			local detail = e.host or e.dns or ""
			local line = ("%s  %s  %s"):format(
				utils.ansi_from_rgb(kind_colors[e.kind] or kind_colors.off, ("%-12s"):format(e.word or "")),
				e.name .. string.rep(" ", width - vim.fn.strdisplaywidth(e.name)),
				utils.ansi_from_rgb(kind_colors.detail, detail)
			)
			table.insert(lines, line)
			by_line[vim.trim(utils.strip_ansi_coloring(line))] = e
		end
		local function picked(selected)
			local out = {}
			for _, line in ipairs(selected or {}) do
				local e = by_line[vim.trim(utils.strip_ansi_coloring(line))]
				if e then
					table.insert(out, e)
				end
			end
			return out
		end
		local fzf_actions = {
			-- Sections whose entries are somewhere to go (workspaces, agents) go there, or start or
			-- resume every marked one; the others show the pick.
			["enter"] = function(selected)
				local entries = picked(selected)
				if #entries == 0 or section_name() ~= name then
					return
				end
				if lists[name].enter then
					for _, e in ipairs(entries) do
						lists[name].enter(e, view)
					end
					return
				end
				state.current[name] = entries[1].id
				state.mode = "logs"
				redraw()
			end,
		}
		local header = { lists[name].enter and "enter open" or "enter show", "tab mark", "ctrl-a all" }
		for _, a in ipairs(actions[name] or {}) do
			local key = a[1]:match("^<leader>(%a)$")
			if key and not a.always and not a.single and not single[a[1]] then
				-- Just the verb ("resume or stop", "delete"), so every key fits on the line.
				table.insert(header, "ctrl-" .. key .. " " .. (a[3]:match("^(%S+ or %S+)") or a[3]:match("^%S+")))
				fzf_actions["ctrl-" .. key] = function(selected)
					local entries = picked(selected)
					if #entries == 0 or section_name() ~= name then
						return
					end
					if #entries > 1 then
						local names = vim.tbl_map(function(e)
							return e.name
						end, entries)
						if vim.fn.confirm(a[3] .. ": " .. table.concat(names, ", ") .. "?", "&yes\n&no", 2) ~= 1 then
							return
						end
						view.batch = true
					end
					for _, e in ipairs(entries) do
						local ok, err = pcall(a[2], e, view)
						if not ok then
							vim.notify(tostring(err), vim.log.levels.ERROR)
						end
					end
					view.batch = nil
					if #entries > 1 then
						vim.notify(a[3] .. ": " .. #entries .. " " .. name)
					end
				end
			end
		end
		fzf.fzf_exec(lines, {
			prompt = name .. "> ",
			-- The global marker is blank (packs/fzf.lua); marking needs one to be seen.
			fzf_opts = {
				["--ansi"] = true,
				["--multi"] = true,
				["--marker"] = "▌",
				-- The picking keys on one line, the section's actions on the next.
				["--header"] = table.concat(vim.list_slice(header, 1, 3), " · ")
					.. "\n"
					.. table.concat(vim.list_slice(header, 4), " · "),
			},
			fzf_colors = { ["marker"] = "#A58BD3", ["selected-bg"] = "#15111D", ["selected-fg"] = "#A58BD3" },
			-- Merged with fzf-lua's other bindings.
			keymap = { fzf = { ["ctrl-a"] = "toggle-all" } },
			actions = fzf_actions,
		})
	end,
	"find in this section, act on several",
	always = true,
}

local mapped = { section = nil, lhs = {} }

-- Terminals sections show in the content window (view.adopt), mapped like the view's own buffers.
local adopted = {}

local function buffers()
	return vim.tbl_filter(function(buf)
		return buf and vim.api.nvim_buf_is_valid(buf)
	end, vim.list_extend({ main_buf, menu_buf }, adopted))
end

-- Map the current section's actions on the view's buffers, in place of the last section's, so
-- which-key lists only what works here. A terminal gets them in terminal mode too, so the leader
-- works while typing into it; which-key holds the space there (packs/whichkey.lua) and hands it to
-- the terminal when no action follows.
function set_actions()
	if mapped.section == section_name() then
		return
	end
	for _, buf in ipairs(buffers()) do
		for _, lhs in ipairs(mapped.lhs) do
			pcall(vim.keymap.del, "n", lhs, { buffer = buf })
			pcall(vim.keymap.del, "t", lhs, { buffer = buf })
		end
	end
	mapped = { section = section_name(), lhs = {} }
	for _, a in ipairs(vim.list_extend(vim.list_slice(actions[section_name()]), { find, close })) do
		table.insert(mapped.lhs, a[1])
		for _, buf in ipairs(buffers()) do
			local modes = vim.list_contains(adopted, buf) and { "n", "t" } or "n"
			vim.keymap.set(modes, a[1], function()
				local entry = current_entry()
				if entry or a.always then
					a[2](entry, view)
				end
			end, { buffer = buf, desc = a[3], nowait = true })
		end
	end
	-- which-key reads a buffer's mappings once, and the actions come after the lists load: have it
	-- read them again, or it adds no leader trigger and the 50ms timeoutlen ends the leader.
	local ok, wk_buf = pcall(require, "which-key.buf")
	if ok and wk_buf.clear then
		for _, buf in ipairs(buffers()) do
			pcall(wk_buf.clear, { buf = buf })
		end
	end
end

local function keymaps(buf, modes)
	local function map(lhs, fn, desc)
		vim.keymap.set(modes or "n", lhs, fn, { buffer = buf, desc = desc, nowait = true })
	end
	map("<M-Left>", function()
		step_tab(-1, "Left")
	end, "previous tab")
	map("<M-Right>", function()
		step_tab(1, "Right")
	end, "next tab")
	map("<M-Up>", function()
		step_section(-1, "Up")
	end, "previous section")
	map("<M-Down>", function()
		step_section(1, "Down")
	end, "next section")
	-- Normal mode only, a terminal needs g and G typed.
	vim.keymap.set("n", "gg", function()
		go_tab(true)
	end, { buffer = buf, desc = "first entry", nowait = true })
	vim.keymap.set("n", "G", function()
		go_tab(false)
	end, { buffer = buf, desc = "last entry", nowait = true })
	-- Oil's - (packs/oil.lua) has no folder to open here.
	vim.keymap.set("n", "-", "<nop>", { buffer = buf })
end

-- Take a section's terminal into the view: its keys, and ALT arrows also in terminal mode, so
-- moving on needs no leaving it first.
function view.adopt(buf)
	vim.b[buf].docker_view = true
	keymaps(buf, { "n", "t" })
	table.insert(adopted, buf)
	mapped.section = nil
	set_actions()
end

-- Let go of a terminal, putting the view's content back in its place first.
function view.release(buf)
	if not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	if main_win and vim.api.nvim_win_is_valid(main_win) and vim.api.nvim_win_get_buf(main_win) == buf then
		vim.api.nvim_win_set_buf(main_win, main_buf)
	end
	adopted = vim.tbl_filter(function(b)
		return b ~= buf
	end, adopted)
	pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

-- Open -------------------------------------------------------------------------------------------

local function scratch(name)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, name)
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "docker"
	-- Marks the view's buffers for which-key's filter (packs/whichkey.lua).
	vim.b[buf].docker_view = true
	keymaps(buf)
	return buf
end

local function plain(win)
	for option, value in pairs({
		number = false,
		relativenumber = false,
		signcolumn = "no",
		foldcolumn = "0",
		statuscolumn = "",
		cursorline = false,
		list = false,
		spell = false,
	}) do
		vim.wo[win][option] = value
	end
end

function M.open()
	local first = vim.api.nvim_get_current_buf()
	main_buf = scratch("docker://content")
	main_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(main_win, main_buf)
	if first ~= main_buf and vim.api.nvim_buf_get_name(first) == "" then
		pcall(vim.api.nvim_buf_delete, first, {})
	end
	plain(main_win)
	vim.wo[main_win].wrap = true

	menu_buf = scratch("docker://sections")
	vim.cmd("rightbelow vertical " .. menu_width() .. "split")
	menu_win = vim.api.nvim_get_current_win()
	vim.api.nvim_win_set_buf(menu_win, menu_buf)
	plain(menu_win)
	vim.wo[menu_win].winfixwidth = true
	vim.wo[menu_win].wrap = false
	vim.api.nvim_set_current_win(main_win)

	-- The cursor stays in the content; a click in the menu picks that section.
	vim.api.nvim_create_autocmd("WinEnter", {
		group = vim.api.nvim_create_augroup("DockerView", { clear = true }),
		callback = function()
			if vim.api.nvim_get_current_win() ~= menu_win then
				return
			end
			local line = vim.api.nvim_win_get_cursor(menu_win)[1]
			vim.api.nvim_set_current_win(main_win)
			if sections[line] and line ~= state.section then
				state.section = line
				state.mode = "logs"
				redraw()
			end
		end,
	})
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = "DockerView",
		callback = function()
			if job then
				job:kill(15)
			end
			vim.api.nvim_ui_send("\27]1337;SetUserVar=docker_view=\7")
		end,
	})
	vim.api.nvim_create_autocmd({ "DirChanged", "VimResized" }, { group = "DockerView", callback = refresh })

	refresh()
	vim.uv.new_timer():start(2000, 2000, vim.schedule_wrap(refresh))
end

vim.api.nvim_create_user_command("Docker", M.open, { desc = "docker view" })

return M
