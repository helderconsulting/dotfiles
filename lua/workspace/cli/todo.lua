local nvim = require("workspace.nvim")
local Todo = require("workspace.models").Todo

local M = {}

local usage = [[
usage: todo [-C dir] add "<one-line task>"     add a follow-up for this repo
       todo [-C dir] list                       open todos for this repo
       todo done <id> ["<what you did>"]        mark a todo you were given done
]]

local function fail(msg)
	vim.uv.fs_write(2, msg .. "\n")
	return 1
end

function M.run(args)
	local dir = vim.uv.cwd()
	if args[1] == "-C" then
		dir = args[2]
		table.remove(args, 1)
		table.remove(args, 1)
	end
	local root = nvim.locate(dir).root
	local store = nvim.new_store(nil, nvim.logger("todo", { pid = vim.uv.os_getpid(), session = vim.env.CLAUDE_CODE_SESSION_ID }))
	local command, now = args[1], nvim.clock()
	local from = vim.env.CLAUDE_CODE_SESSION_ID or "you"

	if command == "add" and args[2] and args[2] ~= "" then
		local id = Todo.new_id(math.random)
		while store:get(Todo, id) do
			id = Todo.new_id(math.random)
		end
		store:update(Todo, id, function(t)
			local fresh = Todo.make(id, args[2], root, from, now)
			for _, f in ipairs(Todo.fields) do
				t[f] = fresh[f]
			end
		end)
		store:log({ type = "todo", event = "added", id = id, root = root, from = from, text = args[2] })
		io.write(id .. "\n")
		return 0
	elseif command == "list" then
		for _, t in ipairs(Todo.listed_in(store:all(Todo), root)) do
			io.write(("%s\t%s\t%s\n"):format(t.id, t.state, t:title()))
		end
		return 0
	elseif command == "done" and args[2] then
		local finished
		store:update(Todo, args[2], function(t, created)
			if created then
				return false
			end
			finished = t:finish(args[3] or "", now)
			return finished
		end)
		if not finished then
			return fail("todo: no open todo " .. args[2] .. " (see: todo list)")
		end
		store:log({ type = "todo", event = "done", id = args[2], note = args[3], session = vim.env.CLAUDE_CODE_SESSION_ID })
		return 0
	end
	vim.uv.fs_write(2, usage)
	return 2
end

return M
