-- The docker view's vms section (configs/docker.lua): the lima VMs, colima's included. Colima keeps
-- its VMs in a lima home of its own and names them after the profile ("colima" for the default one,
-- "colima-<profile>" for the rest), so both homes are listed and colima's go through colima, which
-- also sets up the docker engine in them.
local M = {}

local homes = {
	{ dir = vim.fs.normalize("~/.lima"), colima = false },
	{ dir = vim.fs.normalize("~/.colima/_lima"), colima = true },
}

-- Words of starts and stops still running, by id, kept over the refreshes until they finish.
local pending = {}

local function status(st)
	st = (st or ""):lower()
	if st == "running" then
		return "running", "ok"
	elseif st == "stopped" then
		return "stopped", "off"
	elseif st == "broken" then
		return "broken", "bad"
	end
	return st ~= "" and st or "unknown", "busy"
end

local function profile(name)
	return name == "colima" and "default" or name:gsub("^colima%-", "")
end

function M.fetch(done)
	if vim.fn.executable("limactl") == 0 then
		return done({})
	end
	local list, left = {}, #homes
	for _, home in ipairs(homes) do
		local env = { LIMA_HOME = home.dir }
		vim.system({ "limactl", "list", "--format", "json" }, { text = true, env = env }, function(res)
			vim.schedule(function()
				for _, line in ipairs(vim.split(res.stdout or "", "\n", { trimempty = true })) do
					local ok, vm = pcall(vim.json.decode, line)
					if ok and type(vm) == "table" and vm.name then
						local id = home.dir .. ":" .. vm.name
						local word, kind = status(vm.status)
						if pending[id] then
							word, kind = pending[id], "busy"
						end
						table.insert(list, {
							id = id,
							name = vm.name,
							word = word,
							kind = kind,
							running = vm.status == "Running",
							dir = vm.dir,
							env = env,
							colima = home.colima and profile(vm.name) or nil,
						})
					end
				end
				left = left - 1
				if left == 0 then
					done(list)
				end
			end)
		end)
	end
end

function M.show(entry, mode)
	if mode == "inspect" then
		return {}, { "cat", entry.dir .. "/lima.yaml" }
	end
	return {}, { "tail", "-n", "500", "-F", entry.dir .. "/ha.stderr.log" }
end

-- The command for a VM action: colima's own for its VMs, limactl in the VM's home for the rest.
local function cmd(e, colima, lima)
	if e.colima then
		return vim.list_extend({ "colima" }, vim.list_extend(colima, { "--profile", e.colima }))
	end
	return vim.list_extend({ "limactl" }, vim.list_extend(lima, { e.name }))
end

local function busy(view, e, word, command)
	pending[e.id] = word
	view.refresh()
	view.run(command, {
		env = e.env,
		done = function()
			pending[e.id] = nil
		end,
	})
end

M.actions = {
	{
		"<leader>s",
		function(e, view)
			if e.running then
				busy(view, e, "stopping", cmd(e, { "stop" }, { "stop" }))
			else
				busy(view, e, "starting", cmd(e, { "start" }, { "start", "--tty=false" }))
			end
		end,
		"start or stop vm",
	},
	{
		"<leader>r",
		function(e, view)
			busy(view, e, "restarting", cmd(e, { "restart" }, { "restart" }))
		end,
		"restart vm",
	},
	{
		"<leader>e",
		function(e, view)
			if e.colima then
				view.split({ "colima", "ssh", "--profile", e.colima })
			else
				view.split({ "env", "LIMA_HOME=" .. e.env.LIMA_HOME, "limactl", "shell", e.name })
			end
		end,
		"shell in vm",
	},
	{
		"<leader>i",
		function(_, view)
			view.toggle_mode()
		end,
		"toggle log and config",
	},
	{
		"<leader>d",
		function(e, view)
			if view.confirm("delete vm " .. e.name .. "?") then
				view.run(cmd(e, { "delete", "--force" }, { "delete" }), { env = e.env })
			end
		end,
		"delete vm",
	},
}

return M
