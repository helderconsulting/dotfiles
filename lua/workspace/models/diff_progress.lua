local Model = require("workspace.model")

local DiffProgress = Model.extend({
	kind = "diff_progress",
	fields = { "id", "root", "at", "files" },
})

function DiffProgress.key(root)
	return (root:gsub("/", "%%"))
end

function DiffProgress.for_root(root)
	return DiffProgress:new({ id = DiffProgress.key(root), root = root })
end

function DiffProgress:init()
	self.files = self.files or {}
	self.touched = {}
end

function DiffProgress:file(path)
	self.files[path] = self.files[path] or { hunks = {}, seen = {} }
	self.touched[path] = true
	return self.files[path]
end

function DiffProgress:absorb(mine)
	for path in pairs(mine.touched or {}) do
		local ours, theirs = mine.files[path], self:file(path)
		if ours then
			for key in pairs(ours.seen or {}) do
				theirs.seen[key] = true
			end
			theirs.hunks, theirs.stamp = ours.hunks, ours.stamp
		end
	end
	if mine.at and (not self.at or (mine.at.at or 0) >= (self.at.at or 0)) then
		self.at = mine.at
	end
	self.root = self.root or mine.root
	self.touched = {}
	return true
end

local function same(a, b)
	if #a ~= #b then
		return false
	end
	for i = 1, #a do
		if a[i] ~= b[i] then
			return false
		end
	end
	return true
end

function DiffProgress:know(path, keys, stamp)
	local f = self:file(path)
	local changed = not same(f.hunks, keys) or f.stamp ~= stamp
	f.hunks, f.stamp = keys, stamp
	return changed
end

function DiffProgress:see(path, key)
	local f = self:file(path)
	if f.seen[key] then
		return false
	end
	f.seen[key] = true
	return true
end

function DiffProgress:has_seen(path, key)
	local f = self.files[path]
	return f ~= nil and f.seen[key] == true
end

function DiffProgress:visit(path, line, at)
	if self.at and self.at.path == path and self.at.line == line then
		return false
	end
	self.at = { path = path, line = line, at = at }
	return true
end

function DiffProgress:position()
	return self.at
end

function DiffProgress:tally(path)
	local f = self.files[path]
	if not f then
		return nil
	end
	local seen = 0
	for _, key in ipairs(f.hunks) do
		seen = seen + (f.seen[key] and 1 or 0)
	end
	return seen, #f.hunks
end

function DiffProgress:badge(path, stamp)
	local seen, total = self:tally(path)
	if not seen or total == 0 then
		return nil
	end
	if self.files[path].stamp ~= stamp then
		return seen > 0 and { "changed since seen", "changed" } or nil
	end
	if seen == total then
		return { "✓", "done" }
	end
	return seen > 0 and { ("%d/%d"):format(seen, total), "partly" } or nil
end

return DiffProgress
