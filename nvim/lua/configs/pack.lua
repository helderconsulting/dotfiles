local function collect_packs()
	return vim.pack.get(nil, { info = false })
end

local function confirm_and_delete(names)
	if #names == 0 then
		return
	end
	local msg = "Remove packs:\n" .. table.concat(names, "\n")
	if vim.fn.confirm(msg, "&Yes\n&No", 2) ~= 1 then
		return
	end
	local ok, err = pcall(function()
		vim.pack.del(names)
	end)
	if not ok then
		vim.notify(err, vim.log.levels.ERROR)
	else
		vim.notify("Removed packs: " .. table.concat(names, ", "), vim.log.levels.INFO)
		vim.notify("Remove them from vim.pack.add to avoid re-install on update.", vim.log.levels.WARN)
	end
end

local function update(names)
	local ok, err = pcall(vim.pack.update, names)

	if not ok then
		vim.notify(
			string.format("Failed to update pack(s) [%s]:\n%s", table.concat(names, ", "), tostring(err)),
			vim.log.levels.ERROR,
			{ title = "Pack Manager" }
		)
	else
		vim.notify(
			string.format("Updated pack(s): %s", table.concat(names, ", ")),
			vim.log.levels.INFO,
			{ title = "Pack Manager" }
		)
	end
end

vim.api.nvim_create_user_command("PackUpdate", function()
	local packs = collect_packs()
	if #packs == 0 then
		vim.notify("No packs found.", vim.log.levels.INFO)
		return
	end

	local items = {}
	local by_item = {}
	for _, p in ipairs(packs) do
		local label = p.spec.name
		if p.spec.src then
			label = label .. "  " .. p.spec.src
		end
		table.insert(items, label)
		by_item[label] = p.spec.name
	end

	local ok_fzf, fzf = pcall(require, "fzf-lua")
	if ok_fzf then
		fzf.fzf_exec(items, {
			prompt = "Update pack> ",
			fzf_opts = { ["--multi"] = "" },
			actions = {
				["enter"] = function(selected)
					if not selected or #selected == 0 then
						return
					end
					local names = {}
					for _, item in ipairs(selected) do
						local name = by_item[item]
						if name then
							table.insert(names, name)
						end
					end
					update(names)
				end,
			},
		})
		return
	end

	vim.ui.select(items, { prompt = "Update pack> " }, function(choice)
		if not choice then
			return
		end
		local name = by_item[choice]
		if name then
			confirm_and_delete({ name })
		end
	end)
end, { desc = "Update a vim.pack plugin" })

vim.api.nvim_create_user_command("PackUninstall", function()
	local packs = collect_packs()
	if #packs == 0 then
		vim.notify("No packs found.", vim.log.levels.INFO)
		return
	end

	local items = {}
	local by_item = {}
	for _, p in ipairs(packs) do
		local label = p.spec.name
		if p.spec.src then
			label = label .. "  " .. p.spec.src
		end
		table.insert(items, label)
		by_item[label] = p.spec.name
	end

	local ok_fzf, fzf = pcall(require, "fzf-lua")
	if ok_fzf then
		fzf.fzf_exec(items, {
			prompt = "Uninstall pack> ",
			fzf_opts = { ["--multi"] = "" },
			actions = {
				["enter"] = function(selected)
					if not selected or #selected == 0 then
						return
					end
					local names = {}
					for _, item in ipairs(selected) do
						local name = by_item[item]
						if name then
							table.insert(names, name)
						end
					end
					confirm_and_delete(names)
				end,
			},
		})
		return
	end

	vim.ui.select(items, { prompt = "Uninstall pack> " }, function(choice)
		if not choice then
			return
		end
		local name = by_item[choice]
		if name then
			confirm_and_delete({ name })
		end
	end)
end, { desc = "Uninstall unused vim.pack plugins" })

vim.keymap.set("n", "<leader>u", ":PackUninstall<cr>", { desc = "uninstall unused packs" })
vim.keymap.set("n", "<leader>U", ":PackUpdate<cr>", { desc = "update pack" })
