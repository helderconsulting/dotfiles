local app = require("configs.app")
local Transcript = app.models.Transcript

local M = {}

local entries = {}

local function newest(id)
	local best, mtime
	for _, path in ipairs(vim.fn.glob(app.paths.claude_projects .. "/*/" .. id .. ".jsonl", false, true)) do
		local st = vim.uv.fs_stat(path)
		if st and (not mtime or st.mtime.sec > mtime) then
			best, mtime = path, st.mtime.sec
		end
	end
	return best
end

local function emit(id)
	app.live().bus.emit("transcripts", { id = id })
end

local load

local function watch(e)
	if e.watcher then
		e.watcher:close()
		e.timer:close()
	end
	e.watcher, e.timer = vim.uv.new_fs_event(), vim.uv.new_timer()
	e.watcher:start(e.path, {}, function()
		e.timer:start(200, 0, vim.schedule_wrap(function()
			load(e)
		end))
	end)
end

load = function(e)
	if e.loading then
		e.again = true
		return
	end
	local path = newest(e.id)
	if not path then
		e.transcript = e.transcript or Transcript.new(e.id)
		return emit(e.id)
	end
	e.path = path
	watch(e)
	e.loading = true
	vim.system({ "jq", "-cR", Transcript.filter, path }, { text = true }, function(res)
		vim.schedule(function()
			e.loading = false
			local records = {}
			for line in (res.stdout or ""):gmatch("[^\n]+") do
				local ok, record = pcall(vim.json.decode, line)
				if ok and type(record) == "table" then
					table.insert(records, record)
				end
			end
			e.transcript = Transcript.new(e.id, records)
			emit(e.id)
			if e.again then
				e.again = false
				load(e)
			end
		end)
	end)
end

function M.get(id)
	if not id then
		return nil
	end
	local e = entries[id]
	if not e then
		e = { id = id }
		entries[id] = e
		load(e)
	end
	return e.transcript
end

function M.reload(id)
	local e = entries[id]
	if e then
		load(e)
	end
end

function M.path(id)
	local e = entries[id]
	return e and e.path or newest(id)
end

app.on("agents", function(change)
	local e = entries[change.id]
	local updated = change.model and change.model.updated
	if e and updated ~= e.updated then
		e.updated = updated
		load(e)
	end
end)

return M
