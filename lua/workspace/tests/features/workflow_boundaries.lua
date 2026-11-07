local workspace_dir = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0])))

local function requires(path)
	local text = table.concat(vim.fn.readfile(path), "\n")
	local out = {}
	for module in text:gmatch('require%s*%(?%s*["\']([%w_%.]+)["\']') do
		table.insert(out, module)
	end
	return out
end

local function lua_files(dir)
	return vim.fn.glob(workspace_dir .. "/" .. dir .. "/**/*.lua", false, true)
end

local function relative(path)
	return path:sub(#workspace_dir + 2)
end

local function breaks_screen_boundary(module)
	return module:match("%.domain%.") ~= nil
		or module:match("%.outbound%.") ~= nil
		or module:match("^workspace%.shared%.state%.") ~= nil
		or module:match("^workspace%.workflow%.application%.dto%.") ~= nil
		or module:match("^workspace%.workflow%.application%.mappers%.") ~= nil
end

return function(t)
	local test, check = t.test, t.check

	test("workflow presentation and inbound adapters use only application services and view models", function()
		local files = vim.list_extend(lua_files("workflow/presentation"), lua_files("workflow/infrastructure/inbound"))
		local bad = {}
		for _, path in ipairs(files) do
			for _, module in ipairs(requires(path)) do
				if breaks_screen_boundary(module) then
					table.insert(bad, relative(path) .. " requires " .. module)
				end
			end
		end
		check("no screen or inbound adapter requires a domain model, repository, store, or application dto/mapper", #bad == 0, bad)
	end)

	test("gitlab.lua only talks to the GitLab API", function()
		local path = workspace_dir .. "/workflow/infrastructure/outbound/gitlab.lua"
		local bad = {}
		for _, module in ipairs(requires(path)) do
			if not module:match("^workspace%.shared%.adapters%.") and not module:match("^workspace%.shared%.lib%.") then
				table.insert(bad, module)
			end
		end
		check("gitlab.lua requires only shared adapters and libs, never the app, domain, or commands", #bad == 0, bad)
	end)
end
