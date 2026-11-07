return function(t)
	local test, check, make_store = t.test, t.check, t.make_store

	local function without_vim(fn)
		local saved_vim, saved_loaded, saved_loaders = _G.vim, {}, package.loaders
		local plain = {}
		for i, loader in ipairs(saved_loaders) do
			if debug.getinfo(loader, "S").short_src:sub(1, 4) ~= "vim/" then
				table.insert(plain, loader)
			end
		end
		package.loaders = plain
		for name, module in pairs(package.loaded) do
			if name:find("^workspace%.") then
				saved_loaded[name] = module
				package.loaded[name] = nil
			end
		end
		local saved_unpack, saved_table_unpack = _G.unpack, table.unpack
		table.unpack, _G.unpack = saved_unpack or saved_table_unpack, nil
		_G.vim = nil
		package.loaded["workspace.shared.adapters.nvim"] = setmetatable({}, {
			__index = function()
				error("workspace.shared.adapters.nvim used without vim")
			end,
		})
		local ok, result = xpcall(fn, debug.traceback)
		_G.vim, _G.unpack, table.unpack = saved_vim, saved_unpack, saved_table_unpack
		package.loaders = saved_loaders
		for name in pairs(package.loaded) do
			if name:find("^workspace%.") then
				package.loaded[name] = nil
			end
		end
		for name, module in pairs(saved_loaded) do
			package.loaded[name] = module
		end
		return ok, result
	end

	test("composition_root builds every feature without vim, as WezTerm loads it", function()
		local root = vim.fn.tempname()
		local store = make_store(root)
		local roles
		local ok, services = without_vim(function()
			local built = require("workspace.composition_root").build(store, { clock = os.time })
			roles = built.workspace_process:view_roles()
			built.resource_process:section_names()
			return built
		end)
		check("build doesn't fail without vim", ok, services)
		check("workspace_process exists", ok and services.workspace_process ~= nil)
		check("view_roles works on Lua 5.4, where only table.unpack exists", ok and type(roles) == "table" and #roles > 0, services)
		vim.fn.delete(root, "rf")
	end)

	test("composition_root retries after a feature fails to register", function()
		local composition_root = require("workspace.composition_root")
		local root = vim.fn.tempname()
		local store = make_store(root)
		local workflow = require("workspace.workflow.composition")
		local register = workflow.register
		workflow.register = function()
			error("boom")
		end
		local failed = pcall(composition_root.build, store, { clock = os.time })
		workflow.register = register
		check("the failing build raises", not failed)
		local ok, services = pcall(composition_root.build, store, { clock = os.time })
		check("the next build registers everything again", ok and services.workspace_process ~= nil and services.mandatum_process ~= nil, services)
		check("a good build is cached", composition_root.build(store, { clock = os.time }) == services)
		vim.fn.delete(root, "rf")
	end)
end
