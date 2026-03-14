local result_buffer = nil
local result_window = nil
local query_window = nil
local page_index = 0
local page_size = 2
local connection = "mongodb://localhost:27017"

local open_window = function()
	query_window = vim.api.nvim_get_current_win()
	if not (result_buffer and vim.api.nvim_buf_is_valid(result_buffer)) then
		result_buffer = vim.api.nvim_create_buf(false, true)
	end

	if not (result_window and vim.api.nvim_win_is_valid(result_window)) then
		vim.cmd("botright split")
		result_window = vim.api.nvim_get_current_win()
	end

	vim.api.nvim_win_set_buf(result_window, result_buffer)

	vim.bo[result_buffer].buftype = "nofile"
	vim.bo[result_buffer].bufhidden = "wipe"
	vim.bo[result_buffer].swapfile = false
	vim.bo[result_buffer].filetype = "json"
end

local show_result = function(lines)
	local query = table.concat(lines, "\n")

	local result = vim.fn.system("mongosh --quiet '" .. connection .. "' --eval '" .. query .. "'")

	if result_buffer then
		vim.api.nvim_buf_set_lines(result_buffer, 0, -1, false, vim.split(result, "\n"))
	end
end

vim.api.nvim_create_user_command("QueryDatabase", function(opts)
	local lines = vim.api.nvim_buf_get_lines(0, opts.line1 - 1, opts.line2, false)
	open_window()
	show_result(lines)

	if query_window then
		vim.api.nvim_set_current_win(query_window)
	end
end, { range = true })

local list = function(collection)
	open_window()
	local list = string.format('db.getCollection("%s").find({}).skip(%d).limit(%d)', collection[1], page_index, page_size)
	show_result({ list })
	if query_window then
		vim.api.nvim_set_current_win(query_window)
	end
end

vim.api.nvim_create_user_command("QueryCollection", function()
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok then
		vim.notify("fzf-lua not available", vim.log.levels.WARN)
		return
	end

	local query = "db.getCollectionNames()"

	local result = vim.fn.system("mongosh --quiet '" .. connection .. "' --eval '" .. query .. "'")
	local json = result:gsub("'", '"')
	local c = vim.json.decode(json)
	local lines = vim.split(result, "\n", { trimempty = true })

	local collections = {}
	for _, line in ipairs(lines) do
		table.insert(collections, line)
	end
	if #collections == 0 then
		vim.notify("No collections found", vim.log.levels.INFO)
		return
	end
	fzf.fzf_exec(c, {
		prompt = "Collections> ",
		winopts = { height = 0.35, width = 1.00, row = 1.00, border = "none", preview = { hidden = "hidden" } },
		actions = {
			["enter"] = function(collection)
				list(collection)
				vim.keymap.set("n", "<leader>}", function()
					page_size = page_size + 1
					list(collection)
				end, { noremap = true, buffer = true, desc = "increase page size" })
				vim.keymap.set("n", "<leader>{", function()
					local next_size = page_size - 1
					if next_size > 0 then
						page_size = next_size
					end
					list(collection)
				end, { noremap = true, buffer = true, desc = "decrease page size" })

				vim.keymap.set("n", "<leader>]", function()
					page_index = page_index + 1
					list(collection)
				end, { noremap = true, buffer = true, desc = "next page" })

				vim.keymap.set("n", "<leader>[", function()
					local next_index = page_index - 1
					if next_index > 0 then
						page_index = next_index
					end
					list(collection)
				end, { noremap = true, buffer = true, desc = "previous page" })
			end,
		},
	})
end, { range = true })

vim.keymap.set("v", "<leader>qd", ":QueryDatabase<cr>", { desc = "queries the database with selection" })
vim.keymap.set("n", "<leader>ql", ":QueryCollection<cr>", { desc = "lists the data of selected collection" })
