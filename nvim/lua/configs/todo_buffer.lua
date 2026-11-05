local app = require("configs.app")
local todos = require("configs.todos")

local M = {}

local ns = vim.api.nvim_create_namespace("todo_buffer")

local function text_of(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function header(buf, todo)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	local card = todo:card(todos.names(), app.now())
	vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
		virt_lines = { { { "" } }, { { "  todo · " .. card[1] .. " · " .. card[3], "CardOffDetail" } }, { { "" } } },
		virt_lines_above = true,
	})
end

local function save(buf, id, loud)
	if not vim.bo[buf].modified then
		return true
	end
	local ok, why = todos.save({ todo = id }, text_of(buf))
	if ok then
		vim.bo[buf].modified = false
	elseif loud then
		vim.notify("todo not saved: " .. tostring(why), vim.log.levels.WARN)
	end
	return ok
end

local function create(id)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, "todo://" .. id)
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "markdown"
	local group = vim.api.nvim_create_augroup("TodoBuffer" .. buf, { clear = true })
	vim.api.nvim_create_autocmd("BufWriteCmd", {
		group = group,
		buffer = buf,
		callback = function()
			save(buf, id, true)
		end,
	})
	vim.api.nvim_create_autocmd({ "BufLeave", "InsertLeave" }, {
		group = group,
		buffer = buf,
		callback = function()
			save(buf, id, false)
		end,
	})
	vim.keymap.set({ "n", "i" }, "<C-s>", function()
		vim.cmd.stopinsert()
		save(buf, id, true)
	end, { buffer = buf, desc = "save the todo" })
	return buf
end

function M.buffer(id)
	local todo = todos.todo(id)
	if not todo then
		return nil
	end
	local name = "todo://" .. id
	local buf = vim.fn.bufnr("^" .. vim.fn.escape(name, "\\[]*?~.") .. "$")
	if buf == -1 then
		buf = create(id)
	end
	if not vim.bo[buf].modified and text_of(buf) ~= todo.text then
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(todo.text or "", "\n"))
		vim.bo[buf].modified = false
	end
	vim.bo[buf].modifiable = todo.state ~= "done"
	header(buf, todo)
	return buf
end

return M
