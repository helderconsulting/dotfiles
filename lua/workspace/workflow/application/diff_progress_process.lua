local DiffProgress = require("workspace.workflow.domain.diff_progress")

local DiffProgressProcess = {}
DiffProgressProcess.__index = DiffProgressProcess

local M = {}

function M.new(ports)
	return setmetatable({ progress = ports.progress, cache = {}, dirty = {} }, DiffProgressProcess)
end

function DiffProgressProcess:of(root)
	if not self.cache[root] then
		self.cache[root] = self.progress:get(root) or DiffProgress.for_root(root)
	end
	return self.cache[root]
end

function DiffProgressProcess:know(root, path, keys, stamp)
	local changed = self:of(root):know(path, keys, stamp)
	if changed then
		self.dirty[root] = true
	end
	return changed
end

function DiffProgressProcess:see(root, path, key)
	local saw = self:of(root):see(path, key)
	if saw then
		self.dirty[root] = true
	end
	return saw
end

function DiffProgressProcess:has_seen(root, path, key)
	return self:of(root):has_seen(path, key)
end

function DiffProgressProcess:visit(root, path, line, at)
	local moved = self:of(root):visit(path, line, at)
	if moved then
		self.dirty[root] = true
	end
	return moved
end

function DiffProgressProcess:position(root)
	return self:of(root):position()
end

function DiffProgressProcess:badge(root, path, stamp)
	return self:of(root):badge(path, stamp)
end

function DiffProgressProcess:has_unsaved()
	return next(self.dirty) ~= nil
end

function DiffProgressProcess:flush()
	for root in pairs(self.dirty) do
		self.cache[root] = self.progress:absorb(root, self.cache[root])
	end
	self.dirty = {}
end

function DiffProgressProcess:forget(id)
	for root in pairs(self.cache) do
		if DiffProgress.key(root) == id then
			self.cache[root], self.dirty[root] = nil, nil
		end
	end
end

function DiffProgressProcess:forget_gone(exists)
	for _, record in ipairs(self.progress:all()) do
		if record.root and not exists(record.root) then
			self.progress:remove(record.root)
		end
	end
end

return M
