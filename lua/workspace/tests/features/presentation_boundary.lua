local lua_root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(debug.getinfo(1, "S").source:sub(2))))))

local features = { "infra", "workbench" }

local function allowed(feature, module)
	if not module:match("^workspace%.") then
		return true
	end
	if module:match("^workspace%.[%w_]+%.application%.") then
		return true
	end
	if module:match("^workspace%.[%w_]+%.presentation%.") or module:match("^workspace%.shared%.lib%.") then
		return true
	end
	return module == "workspace.workbench.infrastructure.inbound.nvim_runtime"
end

local function required_modules(source)
	local seen, modules = {}, {}
	for module in source:gmatch("require%s*%(?%s*[\"']([^\"']+)[\"']") do
		if not seen[module] then
			seen[module] = true
			table.insert(modules, module)
		end
	end
	return modules
end

return function(t)
	local test, check = t.test, t.check

	test("infra and workbench presentation only require application services and their own screen state", function()
		local files = {}
		for _, feature in ipairs(features) do
			local dir = lua_root .. "/workspace/" .. feature .. "/presentation"
			for _, file in ipairs(vim.fn.globpath(dir, "**/*.lua", false, true)) do
				table.insert(files, { feature = feature, file = file })
			end
		end
		check("presentation files are found", #files > 0, #files)
		for _, entry in ipairs(files) do
			local rel = entry.file:sub(#lua_root + 2)
			for _, module in ipairs(required_modules(table.concat(vim.fn.readfile(entry.file), "\n"))) do
				check(rel .. " requires " .. module, allowed(entry.feature, module))
			end
		end
	end)
end
