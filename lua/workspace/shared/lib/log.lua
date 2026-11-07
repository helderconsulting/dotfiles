local M = {}

M.levels = { debug = 1, info = 2, warn = 3, error = 4 }

function M.new(opts)
	local min = M.levels[opts.level or "info"] or M.levels.info
	local logger = {}
	local function write(level, event, data)
		if M.levels[level] < min then
			return
		end
		local entry = { at = opts.clock(), level = level, source = opts.source, event = event, data = data }
		for k, v in pairs(opts.context or {}) do
			entry[k] = v
		end
		local ok, line = pcall(opts.json.encode, entry)
		if ok then
			pcall(opts.fs.append, opts.path, line .. "\n")
		end
	end
	for name in pairs(M.levels) do
		logger[name] = function(event, data)
			write(name, event, data)
		end
	end
	function logger.child(source)
		local o = {}
		for k, v in pairs(opts) do
			o[k] = v
		end
		o.source = opts.source .. ":" .. source
		return M.new(o)
	end
	return logger
end

local function nothing() end

M.silent = { debug = nothing, info = nothing, warn = nothing, error = nothing }

function M.silent.child()
	return M.silent
end

return M
