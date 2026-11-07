local app = require("workspace.workbench.presentation.nvim.app")
local mandata = require("workspace.workflow.presentation.nvim.mandatum_actions")
local view_mapper = require("workspace.workflow.presentation.mappers.expeditio_view_mapper")

local M = {}

local ns = vim.api.nvim_create_namespace("mandatum_buffer")

local function text_of(buf)
	return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

local function header(buf, mandatum)
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	vim.api.nvim_buf_set_extmark(buf, ns, 0, 0, {
		virt_lines = { { { "" } }, { { "  " .. view_mapper.to_mandatum_header(mandatum, mandata.names(), app.now()), "CardOffDetail" } }, { { "" } } },
		virt_lines_above = true,
	})
end

local function save(buf, id, loud)
	if not vim.bo[buf].modified then
		return true
	end
	local ok, why = mandata.save({ mandatum = id }, text_of(buf))
	if ok then
		vim.bo[buf].modified = false
	elseif loud then
		vim.notify("mandatum not saved: " .. tostring(why), vim.log.levels.WARN)
	end
	return ok
end

local function create(id)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_name(buf, "mandatum://" .. id)
	vim.bo[buf].buftype = "acwrite"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "markdown"
	local group = vim.api.nvim_create_augroup("MandatumBuffer" .. buf, { clear = true })
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
	end, { buffer = buf, desc = "save the mandatum" })
	return buf
end

function M.buffer(id)
	local mandatum = mandata.mandatum(id)
	if not mandatum then
		return nil
	end
	local name = "mandatum://" .. id
	local buf = vim.fn.bufnr("^" .. vim.fn.escape(name, "\\[]*?~.") .. "$")
	if buf == -1 then
		buf = create(id)
	end
	if not vim.bo[buf].modified and text_of(buf) ~= mandatum.text then
		vim.bo[buf].modifiable = true
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(mandatum.text or "", "\n"))
		vim.bo[buf].modified = false
	end
	vim.bo[buf].modifiable = mandatum.state ~= "done"
	header(buf, mandatum)
	return buf
end

return M
