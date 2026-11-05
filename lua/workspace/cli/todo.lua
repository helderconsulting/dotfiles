local nvim = require("workspace.nvim")
local models = require("workspace.models")
local repo = require("workspace.epics")
local Todo, Epic, Agent = models.Todo, models.Epic, models.Agent

local M = {}

local usage = [[
usage: todo [-C dir] add "<title>" --description "<short, plain>" --criteria "Given …, when …, then …" [--criteria …] [--epic "<title>"]
           add a todo for this repo, in your session's epic or the one named
       todo amend <id> [--title "<title>"] [--description "<short, plain>"] [--criteria "Given …, when …, then …" …]
           fix a todo; --criteria replaces all of its criteria
       todo show <id>                           print a todo
       todo [-C dir] list                       open todos for this repo
       todo done <id> ["<what you did>"]        mark a todo you were given done

A todo is a title, a short plain description, and acceptance criteria written as Given …, when …, then ….
]]

local function fail(msg)
	vim.uv.fs_write(2, msg .. "\n")
	return 1
end

local function flags(args, from)
	local out, positional, i = { criteria = nil }, {}, from
	while i <= #args do
		local a = args[i]
		local key = a:match("^%-%-(%a+)$")
		if key and args[i + 1] then
			if key == "criteria" then
				out.criteria = out.criteria or {}
				table.insert(out.criteria, args[i + 1])
			else
				out[key] = args[i + 1]
			end
			i = i + 2
		else
			table.insert(positional, a)
			i = i + 1
		end
	end
	return out, positional
end

local commands = {}

function commands.add(ctx, args)
	local opts, positional = flags(args, 2)
	local spec = { title = positional[1], description = opts.description, criteria = opts.criteria or {} }
	local ok, why = Todo.validate(spec)
	if not ok then
		return fail("todo: " .. why .. "\n\n" .. usage)
	end
	local title = opts.epic
	if not title then
		local agent = ctx.from ~= "you" and ctx.store:get(Agent, ctx.from)
		title = agent and agent:display_name() or Epic.loose_ends
	end
	local epic = repo.find_or_create(ctx.store, ctx.root, title, ctx.from, ctx.now)
	local id = repo.add(ctx.store, epic, spec, ctx.from, ctx.now)
	ctx.store:log({ type = "todo", event = "added", id = id, root = ctx.root, from = ctx.from, title = spec.title })
	io.write(id .. "\n")
	return 0
end

function commands.amend(ctx, args)
	local id = args[2]
	local opts = flags(args, 3)
	local changes = { title = opts.title, description = opts.description, criteria = opts.criteria }
	if not id or (changes.title == nil and changes.description == nil and changes.criteria == nil) then
		return fail(usage)
	end
	local ok, why = repo.change(ctx.store, id, "amend", changes, ctx.now)
	if not ok then
		return fail("todo: " .. tostring(why))
	end
	ctx.store:log({ type = "todo", event = "amended", id = id, session = ctx.from })
	return 0
end

function commands.show(ctx, args)
	local epic = args[2] and repo.of_todo(ctx.store, args[2])
	local t = epic and epic:todo(args[2])
	if not t then
		return fail("todo: no todo " .. tostring(args[2]))
	end
	io.write(t.text .. "\n")
	return 0
end

function commands.list(ctx)
	for _, t in ipairs(repo.open_todos(ctx.store, ctx.root)) do
		io.write(("%s\t%s\t%s%s\n"):format(t.id, t.state, t:title(), t:is_specified() and "" or "\t(needs details)"))
	end
	return 0
end

function commands.done(ctx, args)
	if not args[2] then
		return fail(usage)
	end
	local finished = repo.change(ctx.store, args[2], "finish", args[3] or "", ctx.now)
	if not finished then
		return fail("todo: no open todo " .. args[2] .. " (see: todo list)")
	end
	ctx.store:log({ type = "todo", event = "done", id = args[2], note = args[3], session = ctx.from })
	return 0
end

function M.run(args)
	local dir = vim.uv.cwd()
	if args[1] == "-C" then
		dir = args[2]
		table.remove(args, 1)
		table.remove(args, 1)
	end
	local command = commands[args[1] or ""]
	if not command then
		vim.uv.fs_write(2, usage)
		return 2
	end
	return command({
		root = nvim.locate(dir).root,
		store = nvim.new_store(nil, nvim.logger("todo", { pid = vim.uv.os_getpid(), session = vim.env.CLAUDE_CODE_SESSION_ID })),
		now = nvim.clock(),
		from = vim.env.CLAUDE_CODE_SESSION_ID or "you",
	}, args)
end

return M
