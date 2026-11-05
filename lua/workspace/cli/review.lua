local nvim = require("workspace.nvim")
local Review = require("workspace.models").Review

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
	local store = nvim.new_store(nil, nvim.logger("review", { pid = vim.uv.os_getpid(), session = vim.env.CLAUDE_CODE_SESSION_ID }))
	local session = vim.env.CLAUDE_CODE_SESSION_ID
	local command, now = args[1], nvim.clock()

	if command == "list" then
		local review = store:get(Review, Review.key(root))
		for _, c in ipairs(review and review:open_comments() or {}) do
			io.write(("%s\t%s\t%s\n"):format(c.id, c:location(), c:one_line()))
		end
		return 0
	elseif command == "resolve" and args[2] then
		local resolved, err
		store:update(Review, Review.key(root), function(r)
			r.root = root
			resolved, err = r:resolve(args[2], args[3] or "", now, session)
			return resolved ~= nil
		end)
		if not resolved then
			return fail("review: " .. err .. " (see: review list)")
		end
		store:log({ type = "review", event = "resolved", root = root, id = resolved.id, path = resolved.path, line1 = resolved.line1, line2 = resolved.line2, text = resolved.text, reply = resolved.reply, session = session })
		return 0
	elseif command == "ready" then
		local ready, why
		store:update(Review, Review.key(root), function(r)
			r.root = root
			ready, why = r:mark_ready(args[2] or "", session, now)
			return ready
		end)
		if not ready then
			return fail("review: " .. why)
		end
		store:log({ type = "review", event = "ready", root = root, note = args[2] or "", session = session })
		return 0
	end
	vim.uv.fs_write(2, usage)
	return 2
end

return M
