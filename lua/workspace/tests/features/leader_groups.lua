local board = require("workspace.workbench.presentation.nvim.board")
local expeditio = require("workspace.workflow.presentation.nvim.expeditio_panel")
local milites = require("workspace.legio.presentation.nvim.miles_panel")
local legio = require("workspace.legio.presentation.nvim.legio_panel")

local GROUPS = { "miles", "mandatum", "expeditio", "legio" }
local OLD_WORDS = { "agent", "todo", "option", "epic", "team" }

return function(t)
	local test, check = t.test, t.check

	local function group_key(name)
		for _, g in ipairs(board.groups) do
			if g[2] == name then
				return g[1]
			end
		end
	end

	local function action(desc)
		for _, a in ipairs(board.actions) do
			if a[3] == desc then
				return a
			end
		end
	end

	local function under(key, lhs)
		return key ~= nil and lhs:sub(1, #key) == key
	end

	test("the sidebar leader groups use the legion names", function()
		local names = {}
		for _, g in ipairs(board.groups) do
			table.insert(names, g[2])
		end
		table.sort(names)
		local want = vim.deepcopy(GROUPS)
		table.sort(want)
		check("exactly miles, mandatum, expeditio and legio", vim.inspect(names) == vim.inspect(want), table.concat(names, ","))
	end)

	test("each group is on its own key, and the key is a letter of its name", function()
		local seen = {}
		for _, name in ipairs(GROUPS) do
			local key = group_key(name)
			check(name .. " has a group on the leader", key ~= nil and key:match("^<leader>%a$") ~= nil, key)
			if key then
				local letter = key:sub(-1)
				check(name .. " key '" .. letter .. "' is a letter of its name", name:find(letter, 1, true) ~= nil, key)
				check(name .. " key '" .. letter .. "' is not shared", not seen[letter], key)
				seen[letter] = true
			end
		end
	end)

	-- the nvim config root and the shared lua root, found from this file's own path
	local here = vim.fs.abspath(debug.getinfo(1, "S").source:sub(2))
	local shared_lua = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(here))))
	local nvim_lua = vim.fs.dirname(shared_lua) .. "/nvim/lua"

	local function read(path)
		local file = io.open(path, "r")
		if not file then
			return nil
		end
		local text = file:read("*a")
		file:close()
		return text
	end

	local function module_path(mod)
		if mod:sub(1, 10) == "workspace." then
			return shared_lua .. "/" .. mod:gsub("%.", "/") .. ".lua"
		end
		return nvim_lua .. "/" .. mod:gsub("%.", "/") .. ".lua"
	end

	-- the sidebar's role table, read from roles.lua as if the app were in the sidebar role
	local function sidebar_role()
		local chunk = loadfile(nvim_lua .. "/configs/roles.lua")
		if not chunk then
			return nil
		end
		local env = setmetatable({
			require = function(mod)
				if mod == "workspace.workbench.presentation.nvim.app" then
					return { role = "sidebar" }
				end
				return require(mod)
			end,
		}, { __index = _G })
		local ok, roles = pcall(function()
			return setfenv(chunk, env)()
		end)
		return ok and roles or nil
	end

	-- every module the sidebar loads: the role's modules and packs, plus configs and packs loaded for every role
	local function sidebar_modules()
		local role = sidebar_role() or {}
		local mods = {}
		for _, m in ipairs(role.modules or {}) do
			table.insert(mods, m)
		end
		for _, p in ipairs(role.packs or {}) do
			table.insert(mods, p)
		end
		for _, init in ipairs({ nvim_lua .. "/configs/init.lua", nvim_lua .. "/packs/init.lua" }) do
			for mod in (read(init) or ""):gmatch('require%("([%w_%.%-]+)"%)') do
				table.insert(mods, mod)
			end
		end
		return mods
	end

	-- every global leader map those modules set, as the text after <leader>
	local function sidebar_leader_maps()
		local maps, seen = {}, {}
		for _, mod in ipairs(sidebar_modules()) do
			if not seen[mod] then
				seen[mod] = true
				for tail in (read(module_path(mod)) or ""):gmatch('"<leader>([^"]+)"') do
					table.insert(maps, tail)
				end
			end
		end
		return maps
	end

	-- l is lsp's codelens map, which only exists in LSP buffers, so the sidebar may use it
	local LOCAL_ONLY = { l = true }

	test("no leader group key shadows a leader map the sidebar loads", function()
		local maps = sidebar_leader_maps()
		check("the sidebar's leader maps can be read", #maps > 0, maps)
		for _, name in ipairs(GROUPS) do
			local key = group_key(name)
			if key then
				local letter = key:sub(-1)
				local hits = {}
				for _, tail in ipairs(maps) do
					if tail:sub(1, 1) == letter and not LOCAL_ONLY[letter] then
						table.insert(hits, "<leader>" .. tail)
					end
				end
				check(name .. " key '" .. letter .. "' prefixes no leader map the sidebar loads", #hits == 0, hits)
			end
		end
	end)

	test("no action is left outside a legion group", function()
		local orphans = {}
		for _, a in ipairs(board.actions) do
			local owned = false
			for _, name in ipairs(GROUPS) do
				owned = owned or under(group_key(name), a[1])
			end
			if not owned then
				table.insert(orphans, a[1] .. " " .. a[3])
			end
		end
		check("every action sits under a legion group", #orphans == 0, orphans)
	end)

	test("deploying a legio is listed under legio, not under mandatum", function()
		local deploy = action("deploy a legio")
		check("deploy a legio is still an action", deploy ~= nil)
		if deploy then
			check("it sits under the legio group", under(group_key("legio"), deploy[1]), deploy[1])
			check("it is no longer under the mandatum key", not under(group_key("mandatum"), deploy[1]), deploy[1])
			check("it still needs a single expeditio selected", deploy.single == true)
		end
	end)

	test("the model and permission mode actions move under miles", function()
		for _, desc in ipairs({ "miles model", "miles permission mode" }) do
			local a = action(desc)
			check(desc .. " is an action", a ~= nil)
			check(desc .. " sits under the miles group", a ~= nil and under(group_key("miles"), a[1]), a and a[1])
		end
	end)

	test("every action keeps a unique key", function()
		local seen, dupes = {}, {}
		for _, a in ipairs(board.actions) do
			if seen[a[1]] then
				table.insert(dupes, a[1])
			end
			seen[a[1]] = true
		end
		check("no duplicate lhs", #dupes == 0, dupes)
	end)

	test("renamed actions describe what they act on in the legion words", function()
		local bad = {}
		for _, a in ipairs(board.actions) do
			for _, word in ipairs(OLD_WORDS) do
				if a[3]:lower():find(word, 1, true) then
					table.insert(bad, a[1] .. " '" .. a[3] .. "' says " .. word)
				end
			end
		end
		check("no description uses an old word", #bad == 0, bad)
	end)

	test("the panels still export their groups and actions", function()
		check("miles panel exports groups", type(milites.groups) == "table" and #milites.groups > 0)
		check("expeditio panel exports actions", type(expeditio.actions) == "table" and #expeditio.actions > 0)
		check("legio panel loads for the board", legio ~= nil)
	end)
end
