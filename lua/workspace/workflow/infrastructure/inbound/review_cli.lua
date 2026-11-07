local nvim = require("workspace.shared.adapters.nvim")
local composition_root = require("workspace.composition_root")
local cli_mapper = require("workspace.workflow.infrastructure.inbound.mappers.review_cli_mapper")

local M = {}

local usage = [[
usage: review [-C dir] list                    open review comments in this worktree
       review [-C dir] resolve <id> [reply]    mark a comment handled, with a short note on what changed
       review [-C dir] ready [summary]         mark this worktree ready for review
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
	local res = vim.system({ "git", "-C", dir, "rev-parse", "--show-toplevel" }, { text = true }):wait()
	if res.code ~= 0 then
		return fail("review: not in a git repository")
	end
	local root = vim.trim(res.stdout)
	local session = require("workspace.shared.providers").current().current_session()
	local store = nvim.new_store(nil, nvim.logger("review", { pid = vim.uv.os_getpid(), session = session }))
	local reviews = composition_root.build(store, { clock = nvim.clock }).review_process
	local command = args[1]

	if command == "list" then
		for _, c in ipairs(reviews:open_comments(root)) do
			io.write(cli_mapper.to_list_line(c))
		end
		return 0
	elseif command == "resolve" and args[2] then
		local resolved, err = reviews:resolve(cli_mapper.to_resolve_command(root, args, session))
		if not resolved then
			return fail("review: " .. err .. " (see: review list)")
		end
		return 0
	elseif command == "ready" then
		local ready, why = reviews:mark_ready(cli_mapper.to_mark_ready_command(root, args, session))
		if not ready then
			return fail("review: " .. why)
		end
		return 0
	end
	vim.uv.fs_write(2, usage)
	return 2
end

return M
