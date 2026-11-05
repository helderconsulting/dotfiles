local nvim = require("workspace.nvim")
local Bridge = require("workspace.bridge")

local M = {}

function M.run()
	local live = nvim.live()
	local stdout = vim.uv.new_pipe(false)
	stdout:open(1)
	local function reply(id, result, err)
		if id then
			stdout:write(vim.json.encode({ id = id, result = result == nil and vim.NIL or result, error = err }) .. "\n")
		end
	end
	local bridge = Bridge.new(live.store, reply)
	live.bus.on("asks", function(change)
		bridge:settle(change.model or live.store:get(live.models.Ask, change.id))
	end)
	local finished = false
	local partial = ""
	local stdin = vim.uv.new_pipe(false)
	stdin:open(0)
	stdin:read_start(function(err, data)
		if err or not data then
			vim.schedule(function()
				bridge:sync({ sessions = {} })
				finished = true
			end)
			return
		end
		partial = partial .. data
		local lines = vim.split(partial, "\n", { plain = true })
		partial = table.remove(lines)
		vim.schedule(function()
			for _, line in ipairs(lines) do
				local ok, msg = pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
				if ok and type(msg) == "table" then
					bridge:handle(msg)
				end
			end
		end)
	end)
	vim.wait(2 ^ 31, function()
		return finished
	end)
	return 0
end

return M
