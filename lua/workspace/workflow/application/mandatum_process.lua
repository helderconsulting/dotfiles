local mapper = require("workspace.workflow.application.mappers.expeditio_dto_mapper")
local Expeditio = require("workspace.workflow.domain.expeditio")
local Mandatum = require("workspace.workflow.domain.mandatum")

local MandatumProcess = {}
MandatumProcess.__index = MandatumProcess

local M = {}

function M.new(ports)
	return setmetatable({
		expeditiones = ports.expeditiones,
		git = ports.git,
		expand_images = ports.expand_images or function(text)
			return text
		end,
		log = ports.log or function() end,
		clock = ports.clock or os.time,
	}, MandatumProcess)
end

M.done_command = Mandatum.done_command
MandatumProcess.done_command = M.done_command
MandatumProcess.template = Mandatum.template
MandatumProcess.loose_ends = Expeditio.loose_ends

function MandatumProcess:expeditiones_in(folder)
	return mapper.to_expeditio_dtos(Expeditio.listed_in(self.expeditiones:all(), folder))
end

function MandatumProcess:all_expeditiones()
	return mapper.to_expeditio_dtos(self.expeditiones:all())
end

function MandatumProcess:expeditio(id)
	local e = id and self.expeditiones:get(id)
	return e and mapper.to_expeditio_dto(e) or nil
end

function MandatumProcess:expeditio_of(mandatum_id)
	local e = mandatum_id and self.expeditiones:of_mandatum(mandatum_id)
	return e and mapper.to_expeditio_dto(e) or nil
end

function MandatumProcess:mandatum(id)
	local m = id and self.expeditiones:mandatum(id)
	return m and mapper.to_mandatum_dto(m) or nil
end

function MandatumProcess:open_mandata(root)
	root = self.git.repo_root(root)
	local list = {}
	for _, e in ipairs(self.expeditiones:all()) do
		if e.root == root then
			for _, m in ipairs(e:mandata()) do
				if m:is_listed() then
					table.insert(list, m)
				end
			end
		end
	end
	return mapper.to_mandatum_dtos(list)
end

function MandatumProcess:in_progress_for(miles_id)
	return mapper.to_mandatum_dtos(Mandatum.in_progress_for(self.expeditiones:all_mandata(), miles_id))
end

function MandatumProcess:free(ids)
	local now, out = self.clock(), {}
	for _, id in ipairs(ids or {}) do
		local m = self.expeditiones:mandatum(id)
		if m and m:is_free(now) then
			table.insert(out, mapper.to_mandatum_dto(m))
		end
	end
	return out
end

function MandatumProcess:parse(text)
	return Mandatum.parse(text)
end

function MandatumProcess:from_review(command)
	local comment = self.expand_images(command.text or "", command.images)
	return Mandatum.render({
		title = comment:match("[^\n]+") or comment,
		description = table.concat(command.quote or {}, "\n"),
		criteria = { "Given , when , then " },
	})
end

function MandatumProcess:check(text)
	return Mandatum.validate(Mandatum.parse(text))
end

function MandatumProcess:check_spec(spec)
	return Mandatum.validate(spec)
end

function MandatumProcess:render(spec)
	return Mandatum.render(spec)
end

function MandatumProcess:orders(ids)
	local list = {}
	for _, id in ipairs(ids) do
		local m = self.expeditiones:mandatum(id)
		if m then
			table.insert(list, m)
		end
	end
	if #list == 1 then
		return list[1]:message()
	end
	local parts = { "Work through these mandata in order:" }
	for _, m in ipairs(list) do
		table.insert(parts, m:message())
	end
	return table.concat(parts, "\n\n")
end

function MandatumProcess:session_title(ids)
	local list = {}
	for _, id in ipairs(ids) do
		table.insert(list, self.expeditiones:mandatum(id))
	end
	if #list == 0 then
		return nil
	end
	return Mandatum.session_title(list, function(expeditio_id)
		local e = self.expeditiones:get(expeditio_id)
		return e and e.title
	end)
end

function MandatumProcess:add_expeditio(command)
	local root = self.git.repo_root(command.root)
	local found = self.expeditiones:find_by_title(root, command.title)
	if found then
		return found.id
	end
	local expeditio = Expeditio.make(self.expeditiones:new_expeditio_id(), command.title, root, command.from or "you", self.clock())
	self.expeditiones:save_expeditio(expeditio)
	self.log({ type = "expeditio", event = "added", id = expeditio.id, root = root, title = command.title })
	return expeditio.id
end

function MandatumProcess:rename_expeditio(command)
	return self.expeditiones:rename_expeditio(command.expeditio_id, command.title)
end

function MandatumProcess:add_mandatum(command)
	local spec = command.text and Mandatum.parse(command.text) or { title = command.title, description = command.description, criteria = command.criteria or {} }
	local ok, why = Mandatum.validate(spec)
	if not ok then
		return nil, why
	end
	local expeditio = command.expeditio_id and self.expeditiones:get(command.expeditio_id)
	if not expeditio then
		local id = self:add_expeditio({ root = command.root, title = command.expeditio_title or Expeditio.loose_ends, from = command.from })
		expeditio = self.expeditiones:get(id)
	end
	local mandatum = expeditio:new_mandatum(self.expeditiones:new_mandatum_id(), spec, command.from or "you", self.clock())
	self.expeditiones:save_mandatum(mandatum)
	self.log({ type = "mandatum", event = "added", id = mandatum.id, root = expeditio.root, from = command.from, title = spec.title })
	return mandatum.id
end

local function change(self, id, fn)
	return self.expeditiones:update_mandatum(id, function(expeditio)
		return fn(expeditio, self.clock())
	end)
end

function MandatumProcess:amend(command)
	return change(self, command.mandatum_id, function(e, now)
		return e:amend_mandatum(command.mandatum_id, { title = command.title, description = command.description, criteria = command.criteria }, now)
	end)
end

function MandatumProcess:edit(command)
	return change(self, command.mandatum_id, function(e, now)
		return e:edit_mandatum(command.mandatum_id, command.text, now)
	end)
end

function MandatumProcess:assign(command)
	return change(self, command.mandatum_id, function(e, now)
		return e:assign_mandatum(command.mandatum_id, command.miles_id, now)
	end)
end

function MandatumProcess:send(command)
	return change(self, command.mandatum_id, function(e, now)
		return e:send_mandatum(command.mandatum_id, command.miles_id, now, command.assigned_as)
	end)
end

function MandatumProcess:release(command)
	return change(self, command.mandatum_id, function(e, now)
		return e:release_mandatum(command.mandatum_id, command.miles_id, now)
	end)
end

function MandatumProcess:hand(command)
	local ok, why = change(self, command.mandatum_id, function(e, now)
		return e:reassign_mandatum(command.mandatum_id, command.from, command.to, now)
	end)
	if ok then
		self.log({ type = "mandatum", event = "handed", id = command.mandatum_id, from = command.from, to = command.to })
	end
	return ok, why
end

function MandatumProcess:finish(command)
	local ok, why = change(self, command.mandatum_id, function(e, now)
		return e:finish_mandatum(command.mandatum_id, command.note, now)
	end)
	if ok then
		self.log({ type = "mandatum", event = "done", id = command.mandatum_id, note = command.note })
	end
	return ok, why
end

function MandatumProcess:drop(mandatum_id)
	return change(self, mandatum_id, function(e, now)
		return e:drop_mandatum(mandatum_id, now)
	end)
end

function MandatumProcess:drop_expeditio(expeditio_id)
	local expeditio = self.expeditiones:get(expeditio_id)
	if not expeditio then
		return false
	end
	for _, m in ipairs(expeditio:mandata()) do
		self:drop(m.id)
	end
	self.expeditiones:delete_expeditio(expeditio_id)
	return true
end

return M
