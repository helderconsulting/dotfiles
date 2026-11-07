local unpack = table.unpack or unpack
local M = {}

local used = {}
local project

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

local function fetch_with(cmd, parse)
	return function(done)
		vim.system(cmd, { text = true }, function(res)
			vim.schedule(function()
				done(res.code == 0 and parse(vim.split(res.stdout, "\n", { trimempty = true })) or nil)
			end)
		end)
	end
end

local function parse_containers(lines)
	local cwd = vim.fn.getcwd()
	local in_project, all = {}, {}
	used = {}
	for _, line in ipairs(lines) do
		local id, name, st, status, service, dir, image, mounts, ports_text = unpack(vim.split(line, "\t"))
		local port = (ports_text or ""):match(":(%d+)%->")
		if id and id ~= "" then
			used[image or ""] = true
			for _, mount in ipairs(vim.split(mounts or "", ",")) do
				used[mount] = true
			end
			local word, kind = container_status(st, status or "")
			table.insert(all, { id = id, name = name, container = name, port = port, word = word, kind = kind })
			if dir and dir ~= "" and vim.fs.relpath(cwd, dir) then
				table.insert(in_project, {
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
	project = #in_project > 0 and vim.fs.basename(cwd) or nil
	return #in_project > 0 and in_project or all
end

local function parse_images(lines)
	local list = {}
	for _, line in ipairs(lines) do
		local id, repo, tag, size = unpack(vim.split(line, "\t"))
		if id and id ~= "" then
			local name = repo == "<none>" and id or tag == "latest" and repo or repo .. ":" .. tag
			local refs = { id, name, repo .. ":" .. tag }
			table.insert(list, { id = id, name = name, refs = refs })
		end
	end
	return list
end

local function parse_volumes(lines)
	local list = {}
	for _, name in ipairs(lines) do
		if name ~= "" then
			table.insert(list, { id = name, name = name, refs = { name } })
		end
	end
	return list
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

M.containers = {
	docker = true,
	fetch = fetch_with({
		"docker",
		"ps",
		"--all",
		"--no-trunc",
		"--format",
		'{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Status}}\t{{.Label "com.docker.compose.service"}}\t{{.Label "com.docker.compose.project.working_dir"}}\t{{.Image}}\t{{.Mounts}}\t{{.Ports}}',
	}, parse_containers),
	show = function(entry, mode)
		if mode == "logs" then
			return {}, { "docker", "logs", "--tail", "500", "--follow", entry.id }
		end
		return {}, { "docker", "container", "inspect", entry.id }
	end,
	actions = {
		{
			"<leader>s",
			function(e, view)
				view.run({ "docker", e.kind == "off" and "start" or "stop", e.id })
			end,
			"start or stop container",
		},
		{
			"<leader>r",
			function(e, view)
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
			function(e, view)
				view.split({ "docker", "exec", "-it", e.id, "sh" })
			end,
			"shell in container",
		},
		{
			"<leader>i",
			function(_, view)
				view.toggle_mode()
			end,
			"toggle logs and inspect",
		},
		remove("container"),
	},
}

M.images = {
	docker = true,
	fetch = fetch_with({ "docker", "image", "ls", "--format", "{{.ID}}\t{{.Repository}}\t{{.Tag}}\t{{.Size}}" }, parse_images),
	show = function(entry)
		return {}, { "docker", "image", "history", "--format", "{{.CreatedSince}}\t{{.Size}}\t{{.CreatedBy}}", entry.id }
	end,
	actions = { remove("image") },
}

M.volumes = {
	docker = true,
	fetch = fetch_with({ "docker", "volume", "ls", "--format", "{{.Name}}" }, parse_volumes),
	show = function(entry)
		return {}, { "docker", "volume", "inspect", entry.id }
	end,
	actions = { remove("volume") },
}

function M.in_use(refs)
	for _, ref in ipairs(refs or {}) do
		if used[ref] == true then
			return true
		end
	end
	return false
end

function M.project()
	return project
end

return M
