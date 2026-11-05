local M = {}

function M.age(at, now)
	local seconds = math.max(0, (now or os.time()) - (at or 0))
	if seconds < 3600 then
		return math.max(1, math.floor(seconds / 60)) .. "m"
	elseif seconds < 86400 then
		return math.floor(seconds / 3600) .. "h"
	end
	return math.floor(seconds / 86400) .. "d"
end

function M.duration(seconds)
	seconds = math.max(0, math.floor(seconds or 0))
	if seconds < 60 then
		return seconds .. "s"
	elseif seconds < 3600 then
		return math.floor(seconds / 60) .. "m"
	end
	return math.floor(seconds / 3600) .. "h"
end

function M.clock(t, now)
	if not t then
		return ""
	end
	local time = os.date("%I:%M %p", t):gsub("^0", ""):lower()
	if os.date("%Y%m%d", t) ~= os.date("%Y%m%d", now or os.time()) then
		time = os.date("%b ", t):lower() .. tonumber(os.date("%d", t)) .. " " .. time
	end
	return time
end

function M.short(path, projects, home)
	path = (path or ""):gsub("/$", "")
	if projects and path:sub(1, #projects + 1) == projects .. "/" then
		return path:sub(#projects + 2)
	end
	if home and path:sub(1, #home) == home then
		return "~" .. path:sub(#home + 1)
	end
	return path
end

function M.basename(path)
	return (path or ""):match("([^/]+)/?$") or ""
end

function M.dirname(path)
	return (path or ""):match("^(.*)/[^/]+/?$") or ""
end

function M.inside(folder, path)
	return folder ~= nil and path ~= nil and (path == folder or path:sub(1, #folder + 1) == folder .. "/")
end

return M
