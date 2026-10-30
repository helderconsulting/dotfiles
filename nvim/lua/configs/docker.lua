-- Docker view for the pane under Neovim that CTRL|ALT w opens (wezterm/agents.lua runs nvim +Docker),
-- in its own Neovim. Laid out like the CodeDiff view: the sections (containers, images, volumes) on
-- the right, the current entry's logs or details on the left. The section's entries are tabs that
-- act like buffers: the WezTerm bar shows them in this pane's entry, labeled with the current one's
-- status (a container's state, whether an image or volume is in use), and ALT left and right page
-- through them. ALT up and down go through the sections; past the ends
-- both move on to the next WezTerm pane like the rest of the ALT arrow grid (configs/keymaps.lua).
-- The actions sit under the leader, where which-key shows only them (packs/whichkey.lua).
local M = {}

local sections = { "containers", "images", "volumes" }

local state = {
	section = 1,
	entries = { containers = {}, images = {}, volumes = {} },
	-- The id of the current tab per section, kept while the lists refresh.
	current = {},
	down = false,
	-- The project folder when the containers are the project's, nil when they are all of them.
	project = nil,
	-- Content of the current tab: "logs" or "inspect" for containers.
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
	elseif st == "restarting" then
		return "restarting", "busy"
	elseif st == "dead" then
		return "dead", "bad"
	end
	return st, "off"
end

local lists = {
	containers = {
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
}

local function section_name()
	return sections[state.section]
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
	local payload = vim.json.encode({
		section = section_name(),
		project = state.project or "all",
		down = state.down,
		tabs = tabs,
	})
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
	local key = entry and (name .. ":" .. entry.id .. ":" .. state.mode) or (name .. (state.down and ":down" or ":none"))
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
	if state.down then
		set_content({ "", " the docker engine isn't running", " start it with: brew services start colima" })
	elseif not entry then
		set_content({ "", " no " .. name })
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

local function redraw()
	render_menu()
	show()
	report()
end

-- Refresh ----------------------------------------------------------------------------------------

local function refresh()
	local pending = #sections
	local down = false
	for _, name in ipairs(sections) do
		vim.system(lists[name].cmd, { text = true }, function(res)
			vim.schedule(function()
				if res.code ~= 0 then
					down = true
					state.entries[name] = {}
				else
					local list = lists[name].parse(vim.split(res.stdout, "\n", { trimempty = true }))
					table.sort(list, function(a, b)
						return a.name < b.name
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
			end)
		end)
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

local function run(cmd)
	vim.system(cmd, { text = true }, function(res)
		vim.schedule(function()
			if res.code ~= 0 then
				vim.notify(vim.trim(res.stderr), vim.log.levels.ERROR)
			end
			refresh()
		end)
	end)
end

local function container(fn)
	return function()
		local entry = current_entry()
		if section_name() == "containers" and entry then
			fn(entry)
		end
	end
end

local actions = {
	{
		"<leader>s",
		container(function(e)
			run({ "docker", e.kind == "off" and "start" or "stop", e.id })
		end),
		"start or stop container",
	},
	{
		"<leader>r",
		container(function(e)
			run({ "docker", "restart", e.id })
		end),
		"restart container",
	},
	{
		"<leader>e",
		container(function(e)
			vim.system({ "wezterm", "cli", "split-pane", "--pane-id", vim.env.WEZTERM_PANE, "--right", "--", "docker", "exec", "-it", e.id, "sh" })
		end),
		"shell in container",
	},
	{
		"<leader>i",
		container(function()
			state.mode = state.mode == "logs" and "inspect" or "logs"
			redraw()
		end),
		"toggle logs and inspect",
	},
	{
		"<leader>d",
		function()
			local entry = current_entry()
			if not entry or vim.fn.confirm("remove " .. entry.name .. "?", "&yes\n&no", 2) ~= 1 then
				return
			end
			local kind = ({ containers = "container", images = "image", volumes = "volume" })[section_name()]
			run({ "docker", kind, "rm", entry.id })
		end,
		"remove",
	},
	-- Like <leader>- on the diff view: closes the whole view, and with it the pane, since WezTerm
	-- runs it without a shell to fall back to.
	{
		"<leader>-",
		function()
			vim.cmd("qa")
		end,
		"close docker view",
	},
}

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
	for _, a in ipairs(actions) do
		map(a[1], a[2], a[3])
	end
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
