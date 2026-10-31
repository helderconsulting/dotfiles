-- Docker view for the pane under Neovim that CTRL|ALT w opens (wezterm/agents.lua runs nvim +Docker),
-- in its own Neovim. Laid out like the CodeDiff view: the sections (containers, images, volumes) on
-- the right, the current entry's logs or details on the left. The section's entries are tabs that
-- act like buffers: the WezTerm bar shows them in this pane's entry, labeled with the current one's
-- status (a container's state, whether an image or volume is in use), and ALT left and right page
-- through them. ALT up and down go through the sections; past the ends
-- both move on to the next WezTerm pane like the rest of the ALT arrow grid (configs/keymaps.lua).
-- The actions sit under the leader, where which-key shows only the current section's (packs/whichkey.lua).
-- Below the docker sections sit the lima VMs (configs/vms.lua), the remote desktops opened with
-- FreeRDP (configs/desktops.lua) and the devices on the Tailscale VPN (configs/tailscale.lua).
local M = {}

local vms = require("configs.vms")
local desktops = require("configs.desktops")
local tailscale = require("configs.tailscale")

local sections = { "containers", "images", "volumes", "vms", "desktops", "vpn devices" }

local state = {
	section = 1,
	entries = { containers = {}, images = {}, volumes = {}, vms = {}, desktops = {}, ["vpn devices"] = {} },
	-- The id of the current tab per section, kept while the lists refresh.
	current = {},
	down = false,
	-- The project folder when the containers are the project's, nil when they are all of them.
	project = nil,
	-- Content of the current tab: "logs" or "inspect" for containers and VMs.
	mode = "logs",
}

local main_win, main_buf, menu_win, menu_buf
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
			'{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Label "com.docker.compose.service"}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Image}}\t{{.Mounts}}',
		},
		-- The project's containers (compose file in the cwd or below it) by service, or all of them
		-- by name when the project has none. Every container's image and volumes count as in use.
		parse = function(lines)
			local cwd = vim.fn.getcwd()
			local project, all = {}, {}
			state.used = {}
			for _, line in ipairs(lines) do
				local id, name, st, status, service, dir, image, mounts = unpack(vim.split(line, "\t"))
				if id and id ~= "" then
					state.used[image or ""] = true
					for _, mount in ipairs(vim.split(mounts or "", ",")) do
						state.used[mount] = true
					end
					local word, kind = container_status(st, status or "")
					table.insert(all, { id = id, name = name, word = word, kind = kind })
					if dir and dir ~= "" and vim.fs.relpath(cwd, dir) then
						table.insert(project, { id = id, name = service ~= "" and service or name, word = word, kind = kind })
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
	}
	-- A section with a state of its own (the VPN's) labels the bar with it on every tab, and the
	-- current entry's status goes where the project would.
	local section = lists[section_name()]
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
	local width = menu_win and vim.api.nvim_win_is_valid(menu_win) and vim.api.nvim_win_get_width(menu_win) or 18
	local lines = {}
	for _, name in ipairs(sections) do
		local count = tostring(#state.entries[name])
		table.insert(lines, " " .. name .. string.rep(" ", math.max(width - #name - #count - 2, 1)) .. count)
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

local function show()
	local name, entry = section_name(), current_entry()
	local key = entry and (name .. ":" .. entry.id .. ":" .. state.mode)
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
		local lines, cmd = lists[name].show(entry, state.mode)
		set_content(lines)
		if cmd then
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
	local target = list[(index or 0) + delta]
	if not target then
		return hand_off(direction)
	end
	state.current[section_name()] = target.id
	state.mode = "logs"
	redraw()
end

local function step_section(delta, direction)
	local target = state.section + delta
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
		function(e)
			if vim.fn.confirm("remove " .. e.name .. "?", "&yes\n&no", 2) == 1 then
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

-- Pick an entry of the current section with fzf-lua, filtering on its status, name, and host or
-- address, colored like the bar's labels; the pick becomes the current tab.
local kind_colors = { ok = "#77DD77", busy = "#A58BD3", bad = "#E0955A", off = "#8C8C8C", detail = "#3F6F3F" }

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
			by_line[vim.trim(utils.strip_ansi_coloring(line))] = e.id
		end
		fzf.fzf_exec(lines, {
			prompt = name .. "> ",
			fzf_opts = { ["--ansi"] = true },
			actions = {
				["enter"] = function(selected)
					local id = selected and selected[1] and by_line[vim.trim(utils.strip_ansi_coloring(selected[1]))]
					if id and section_name() == name then
						state.current[name] = id
						state.mode = "logs"
						redraw()
					end
				end,
			},
		})
	end,
	"find in this section",
	always = true,
}

local mapped = { section = nil, lhs = {} }

-- Map the current section's actions on the view's buffers, in place of the last section's, so
-- which-key lists only what works here.
function set_actions()
	if mapped.section == section_name() then
		return
	end
	for _, buf in ipairs({ main_buf, menu_buf }) do
		if buf and vim.api.nvim_buf_is_valid(buf) then
			for _, lhs in ipairs(mapped.lhs) do
				pcall(vim.keymap.del, "n", lhs, { buffer = buf })
			end
		end
	end
	mapped = { section = section_name(), lhs = {} }
	for _, a in ipairs(vim.list_extend(vim.list_slice(actions[section_name()]), { find, close })) do
		table.insert(mapped.lhs, a[1])
		for _, buf in ipairs({ main_buf, menu_buf }) do
			if buf and vim.api.nvim_buf_is_valid(buf) then
				vim.keymap.set("n", a[1], function()
					local entry = current_entry()
					if entry or a.always then
						a[2](entry, view)
					end
				end, { buffer = buf, desc = a[3], nowait = true })
			end
		end
	end
end

local function keymaps(buf)
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, nowait = true })
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
	-- Oil's - (packs/oil.lua) has no folder to open here.
	map("-", "<nop>")
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
	vim.cmd("rightbelow vertical 22split")
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
