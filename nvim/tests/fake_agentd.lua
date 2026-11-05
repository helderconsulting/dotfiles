local socket = arg[1]
local f = io.open(socket .. ".pid", "w")
f:write(tostring(vim.uv.os_getpid()))
f:close()
local server = vim.uv.new_pipe(false)
server:bind(socket)
server:listen(16, function()
	local client = vim.uv.new_pipe(false)
	server:accept(client)
	local buf = ""
	client:read_start(function(_, data)
		if not data then
			return client:close()
		end
		buf = buf .. data
		local line = buf:match("^(.-)\n")
		if not line then
			return
		end
		buf = ""
		local req = vim.json.decode(line)
		if req.op == "hold" then
			client:write(vim.json.encode({ ok = true, keep = true, bridge = "up" }) .. "\n")
		else
			client:write(vim.json.encode({ ok = true, op = req.op }) .. "\n", function()
				client:close()
			end)
		end
	end)
end)
vim.wait(30000, function()
	return false
end)
