local layout_module = "workspace.workbench.presentation.wezterm.layout"
local state_module = "workspace.workbench.presentation.wezterm.state"

local function fake_tab(cols, rows)
	local tab = { cols = cols, rows = rows, rects = {}, next_id = 1, focus = nil }

	local function handle(id)
		return {
			pane_id = function()
				return id
			end,
			activate = function()
				tab.focus = id
			end,
			split = function(_, opts)
				return handle(tab:split(id, opts))
			end,
		}
	end

	function tab:add(left, top, width, height)
		local id = self.next_id
		self.next_id = id + 1
		self.rects[id] = { left = left, top = top, width = width, height = height }
		return id
	end

	function tab:split(id, opts)
		local r = self.rects[id]
		local size = opts.size
		if opts.direction == "Left" then
			assert(r.width - size - 1 >= 1, "no room to split left")
			local new = self:add(r.left, r.top, size, r.height)
			r.left, r.width = r.left + size + 1, r.width - size - 1
			return new
		elseif opts.direction == "Right" then
			assert(r.width - size - 1 >= 1, "no room to split right")
			r.width = r.width - size - 1
			return self:add(r.left + r.width + 1, r.top, size, r.height)
		end
		assert(r.height - size - 1 >= 1, "no room to split below")
		r.height = r.height - size - 1
		return self:add(r.left, r.top + r.height + 1, r.width, size)
	end

	function tab:adjust(id, amount, dir)
		local r = self.rects[id]
		if dir == "Right" then
			local edge = r.left + r.width
			for _, o in pairs(self.rects) do
				if o.left == edge + 1 and o.top == r.top and o.width - amount >= 1 then
					r.width, o.left, o.width = r.width + amount, o.left + amount, o.width - amount
					return
				end
			end
		else
			for _, o in pairs(self.rects) do
				if o.left + o.width + 1 == r.left and o.top == r.top and o.width - amount >= 1 then
					r.left, r.width, o.width = r.left - amount, r.width + amount, o.width - amount
					return
				end
			end
		end
	end

	function tab:resize(cols, rows)
		for _, r in pairs(self.rects) do
			if r.left + r.width == self.cols then
				r.width = r.width + (cols - self.cols)
			end
			if r.top + r.height == self.rows then
				r.height = r.height + (rows - self.rows)
			end
		end
		self.cols, self.rows = cols, rows
	end

	function tab:close(id)
		self.rects[id] = nil
	end

	function tab:count()
		local n = 0
		for _ in pairs(self.rects) do
			n = n + 1
		end
		return n
	end

	function tab:panes_with_info()
		local list = {}
		for id, r in pairs(self.rects) do
			table.insert(list, { pane = handle(id), left = r.left, top = r.top, width = r.width, height = r.height })
		end
		return list
	end

	function tab:get_size()
		return { cols = self.cols, rows = self.rows }
	end

	function tab:active_pane()
		return self.focus and handle(self.focus) or nil
	end

	tab.handle = handle
	return tab
end

local function fake_wezterm(tab)
	return {
		executable_dir = "/fake/bin",
		shell_quote_arg = function(s)
			return "'" .. s .. "'"
		end,
		run_child_process = function(args)
			if args[3] == "adjust-pane-size" then
				tab:adjust(tonumber(args[5]), tonumber(args[7]), args[8])
			end
			return true, "", ""
		end,
	}
end

local function with_layout(tab, workbench, fn)
	local names = { "wezterm", state_module, layout_module }
	local saved = {}
	for _, name in ipairs(names) do
		saved[name] = package.loaded[name]
	end
	local logs = {}
	local function record(level)
		return function(name, fields)
			table.insert(logs, { level = level, name = name, fields = fields })
		end
	end
	package.loaded.wezterm = fake_wezterm(tab)
	package.loaded[state_module] = {
		log = { info = record("info"), warn = record("warn"), error = record("error") },
		workbench = function()
			return workbench
		end,
	}
	package.loaded[layout_module] = nil
	local ok, err = pcall(function()
		fn(require(layout_module), logs)
	end)
	for _, name in ipairs(names) do
		package.loaded[name] = saved[name]
	end
	if not ok then
		error(err, 0)
	end
end

local function warned(logs, role)
	for _, entry in ipairs(logs) do
		if entry.level == "warn" and entry.name == "layout.no_room" and entry.fields.role == role then
			return true
		end
	end
	return false
end

local function grow(layout, tab, w, cols, rows)
	tab:resize(cols, rows)
	layout.grow(tab, w)
	layout.apply(tab, w)
end

return function(t)
	local test, check = t.test, t.check
	local Workspace = require("workspace.workbench.domain.workspace")
	local workbench = require("workspace.composition_root").build(t.make_store(vim.fn.tempname()), {}).workspace_process

	local function opened(cols, rows)
		local tab = fake_tab(cols, rows)
		local w = Workspace:new({ id = "7", root = "/code/app", mode = "full", panes = {} })
		w:set_pane("editor", tab:add(0, 0, cols, rows))
		return tab, w
	end

	test("a workspace skipped for room gets its conversation panel when the window goes fullscreen", function()
		local tab, w = opened(99, 50)
		with_layout(tab, workbench, function(layout, logs)
			layout.ensure(tab, w)
			check("no conversation panel in a 99-column window", w:pane("conversation") == nil, w.panes)
			check("the skip is logged as no_room", warned(logs, "conversation"), logs)

			tab.focus = w:pane("sidebar")
			grow(layout, tab, w, 200, 50)

			local conversation = w:pane("conversation")
			check("the conversation panel is split in after the window grows", conversation ~= nil and tab.rects[conversation] ~= nil, w.panes)
			check("the conversation panel gets its minimum width", conversation ~= nil and tab.rects[conversation].width >= 32, conversation and tab.rects[conversation])
			check("the conversation panel does not add a duplicate pane", tab:count() == 4, tab:count())
			check("focus stays where the user left it", tab.focus == w:pane("sidebar"), tab.focus)
		end)
	end)

	test("a panel the user closed on purpose is not recreated when the window resizes", function()
		local tab, w = opened(200, 53)
		with_layout(tab, workbench, function(layout)
			layout.ensure(tab, w)
			check("docker is created in a tall full-width window", w:pane("docker") ~= nil and tab.rects[w:pane("docker")] ~= nil, w.panes)

			tab:close(w:pane("docker"))
			grow(layout, tab, w, 220, 53)

			check("the closed docker panel stays closed", tab.rects[w:pane("docker") or -1] == nil, w.panes)
			check("only the remaining three panels exist", tab:count() == 3, tab:count())
		end)
	end)

	test("a docker panel skipped for room is added when the window grows taller", function()
		local tab, w = opened(200, 14)
		with_layout(tab, workbench, function(layout, logs)
			layout.ensure(tab, w)
			check("no docker panel in a short window", w:pane("docker") == nil, w.panes)
			check("the docker skip is logged as no_room", warned(logs, "docker"), logs)

			grow(layout, tab, w, 200, 53)

			local docker = w:pane("docker")
			check("the docker panel is split in after the window grows", docker ~= nil and tab.rects[docker] ~= nil, w.panes)
		end)
	end)
end
