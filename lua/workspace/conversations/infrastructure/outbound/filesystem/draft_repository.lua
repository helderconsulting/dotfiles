local Draft = require("workspace.conversations.domain.draft")

local Repository = {}
Repository.__index = Repository

local M = {}

function M.new(paths)
	return setmetatable({ paths = paths }, Repository)
end

local function read(path)
	local f = io.open(path)
	if not f then
		return nil
	end
	local text = f:read("*a")
	f:close()
	return text
end

local function write(path, text)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	local f = io.open(path, "w")
	if f then
		f:write(text)
		f:close()
	end
end

function Repository:file(target)
	return self.paths.draft(Draft.key(target))
end

function Repository:images_file(target)
	return (self:file(target):gsub("%.md$", ".images.json"))
end

function Repository:load(target)
	local file = self:file(target)
	local st = vim.uv.fs_stat(file)
	if not st then
		return nil
	end
	local ok, images = pcall(vim.json.decode, read(self:images_file(target)) or "")
	return Draft.new(
		target,
		vim.trim(read(file) or ""),
		ok and type(images) == "table" and images or {},
		st.mtime.sec,
		st.birthtime and st.birthtime.sec
	)
end

function Repository:write(target, text)
	write(self:file(target), text)
end

function Repository:write_images(target, images)
	write(self:images_file(target), vim.json.encode(images))
end

function Repository:discard(target)
	os.remove(self:file(target))
	os.remove(self:images_file(target))
end

function Repository:capture_clipboard_image()
	vim.fn.mkdir(self.paths.images, "p")
	local path = ("%s/%s-%d.png"):format(self.paths.images, os.date("%Y%m%d-%H%M%S"), vim.uv.hrtime() % 1000)
	local res = vim.system({
		"osascript",
		"-e",
		"set png to (the clipboard as «class PNGf»)",
		"-e",
		('set f to open for access POSIX file "%s" with write permission'):format(path),
		"-e",
		"write png to f",
		"-e",
		"close access f",
	}):wait()
	if res.code ~= 0 then
		os.remove(path)
		return nil
	end
	return path
end

return M
