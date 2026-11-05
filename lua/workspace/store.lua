local Store = {}
Store.__index = Store

local M = {}

M.lock_stale = 2
M.lock_wait = 3000

function M.new(opts)
	local self = setmetatable({}, Store)
	self.paths = opts.paths
	self.fs = opts.fs
	self.json = opts.json
	self.clock = opts.clock
	self.random = opts.random
	self.on_change = opts.on_change
	self.locking = opts.locking ~= false
	self.logger = opts.logger or require("workspace.log").silent
	return self
end

function Store:file(cls, id)
	return self.paths.entity(cls.kind, id)
end

function Store:read(cls, id)
	local text = self.fs.read(self:file(cls, id))
	if not text or text == "" then
		return nil
	end
	local ok, data = pcall(self.json.decode, text)
	return ok and type(data) == "table" and data or nil
end

function Store:get(cls, id)
	local data = self:read(cls, id)
	return data and cls:new(data) or nil
end

function Store:ids(cls)
	local ids = {}
	for _, name in ipairs(self.fs.list(self.paths.dir(cls.kind))) do
		local id = name:match("^(.+)%.json$")
		if id then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	return ids
end

function Store:all(cls)
	local list = {}
	for _, id in ipairs(self:ids(cls)) do
		local model = self:get(cls, id)
		if model then
			table.insert(list, model)
		end
	end
	return list
end

function Store:acquire(cls, id)
	if not self.locking then
		return function() end
	end
	local path = self.paths.lock(cls.kind, id)
	self.fs.mkdirp(self.paths.locks)
	local waited = 0
	while not self.fs.mkdir(path) do
		local mtime = self.fs.mtime(path)
		if (mtime and self.clock() - mtime > M.lock_stale) or waited > M.lock_wait then
			self.fs.rmdir(path)
		else
			self.fs.sleep(5)
			waited = waited + 5
		end
	end
	return function()
		self.fs.rmdir(path)
	end
end

function Store:bump()
	self.fs.write(self.paths.version, tostring(self.clock()) .. "-" .. tostring(self.random(0, 0x7fffffff)))
end

function Store:log(entry)
	entry.at = entry.at or self.clock()
	self.fs.append(self.paths.log, self.json.encode(entry) .. "\n")
end

function Store:update(cls, id, fn)
	local release = self:acquire(cls, id)
	local data = self:read(cls, id)
	local model = cls:new(data or { id = id })
	model.id = id
	local ok, result = pcall(fn, model, data == nil)
	if not ok then
		release()
		error(result, 0)
	end
	if result == false then
		release()
		model:take_transitions()
		return model
	end
	local path = self:file(cls, id)
	self.fs.mkdirp(self.paths.dir(cls.kind))
	if result == "delete" then
		self.fs.remove(path)
	else
		self.fs.write(path, self.json.encode(model:to_table()))
	end
	self:bump()
	release()
	local transitions = model:take_transitions()
	self.logger.debug("store.update", { kind = cls.kind, id = id, deleted = result == "delete", transitions = transitions })
	for _, t in ipairs(transitions) do
		if t.rejected then
			self.logger.warn("transition.rejected", { kind = cls.kind, id = id, item = t.item, event = t.event, from = t.from })
		end
		self:log({ type = "transition", kind = cls.kind, id = id, item = t.item, event = t.event, from = t.from, to = t.to, rejected = t.rejected })
	end
	if self.on_change then
		self.on_change(cls, model, transitions, result == "delete")
	end
	return model
end

function Store:remove(cls, id)
	return self:update(cls, id, function()
		return "delete"
	end)
end

return M
