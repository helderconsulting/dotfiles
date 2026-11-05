local app = require("configs.app")
local MergeRequest, Review, DiffProgress = app.models.MergeRequest, app.models.Review, app.models.DiffProgress

local M = {}

local remotes = {}

local function loaded_at(path)
	local st = path and vim.uv.fs_stat(path)
	return st and st.mtime.sec or 0
end

M.code = math.max(
	loaded_at(debug.getinfo(1, "S").source:gsub("^@", "")),
	loaded_at(package.searchpath("workspace.models.merge_request", package.path))
)

local function log()
	return app.live().log
end

local function api(root, args, done)
	local cmd = vim.list_extend({ "glab", "api" }, args)
	vim.system(cmd, { cwd = root, text = true }, vim.schedule_wrap(function(res)
		if res.code ~= 0 then
			return done(nil, vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or ("glab exited " .. res.code))
		end
		done(res.stdout)
	end))
end

local function graphql(root, path, branch, done)
	api(root, { "graphql", "-f", "query=" .. MergeRequest.query, "-f", "path=" .. path, "-f", "branch=" .. branch }, function(out, err)
		if not out then
			return done(nil, err)
		end
		local ok, data = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
		if not ok or type(data) ~= "table" then
			return done(nil, "bad json from gitlab graphql")
		elseif data.errors then
			return done(nil, tostring((data.errors[1] or {}).message or "gitlab graphql error"))
		end
		done(data.data or {})
	end)
end

local function ndjson(root, path, done)
	api(root, { "--paginate", "--output", "ndjson", path }, function(out, err)
		if not out then
			return done(nil, err)
		end
		local list = {}
		for line in out:gmatch("[^\n]+") do
			local ok, item = pcall(vim.json.decode, line)
			if ok then
				table.insert(list, item)
			end
		end
		done(list)
	end)
end

local function project_of(root)
	if remotes[root] == nil then
		local res = vim.system({ "git", "-C", root, "remote", "get-url", "origin" }, { text = true }):wait()
		local url = res.code == 0 and res.stdout or ""
		remotes[root] = url:match("gitlab") and MergeRequest.project_path(url) or false
	end
	return remotes[root] or nil
end

function M.get(root)
	local mr = root and app.store():get(MergeRequest, MergeRequest.key(root))
	if not mr then
		return nil
	end
	local review = app.store():get(Review, Review.key(root))
	return mr:attach({ addressed = review ~= nil and review:addresses(mr.iid) })
end

function M.label(root)
	local mr = M.get(root)
	return mr and mr:label()
end

local function quote(c)
	if not (c.key and c.line1 and vim.fn.filereadable(c.key) == 1) then
		return {}
	end
	return vim.list_slice(vim.fn.readfile(c.key, "", c.line2 or c.line1), c.line1, c.line2 or c.line1)
end

local function hand_over(root, mr, list)
	if #list == 0 then
		return
	end
	local agent = Review.recipient(app.agents(), root)
	local what = ("%d GitLab comment%s on !%s"):format(#list, #list == 1 and "" or "s", mr.iid)
	if not agent then
		return vim.notify("review: " .. what .. " saved as drafts, no single agent works in " .. vim.fs.basename(root) .. ". Send with <leader>rs", vim.log.levels.INFO)
	end
	local cli = ("%s -C %s"):format(Review.cli, vim.fn.shellescape(root))
	local text = Review.prompt(list, cli, quote, function(c)
		return c.text
	end)
	require("configs.runner").message(agent, text, function(ok)
		if not ok then
			return
		end
		local ids = {}
		for _, c in ipairs(list) do
			ids[c.id] = true
		end
		app.store():update(Review, Review.key(root), function(r)
			local outgoing = vim.tbl_filter(function(c)
				return ids[c.id] and c:is_draft()
			end, r.comments)
			r:send(outgoing, app.now(), agent.id)
			return #outgoing > 0
		end)
		for _, c in ipairs(list) do
			app.store():log({ type = "review", event = "sent", root = root, id = c.id, path = c.path, line1 = c.line1, line2 = c.line2, text = c.text, session = agent.id, remote = c.remote })
		end
		vim.notify(("review: sent %s to %s"):format(what, agent:display_name()))
	end)
end

local function push(root, mr)
	local r = app.store():get(Review, Review.key(root))
	for _, c in ipairs(r and r:unpushed(mr.iid) or {}) do
		local base = ("projects/:id/merge_requests/%s/discussions/%s"):format(mr.iid, c.remote.thread)
		api(root, { "--method", "POST", base .. "/notes", "-f", "body=" .. (c.reply ~= "" and c.reply or "Done.") }, function(_, err)
			if err then
				return log().warn("gitlab.reply.failed", { root = root, id = c.id, error = err })
			end
			api(root, { "--method", "PUT", base, "-F", "resolved=true" }, function(_, rerr)
				if rerr then
					log().warn("gitlab.resolve.failed", { root = root, id = c.id, error = rerr })
				end
				app.store():update(Review, Review.key(root), function(review)
					return review:mark_pushed(c.id, (c.remote.notes or 0) + 1)
				end)
			end)
		end)
	end
end

local function sync(root, mr, discussions)
	local threads = MergeRequest.threads(discussions)
	local changes
	app.store():update(Review, Review.key(root), function(r)
		r.root = root
		changes = r:import(threads, mr.iid, math.random, app.now())
		return #changes.added + #changes.reopened + #changes.closed > 0
	end)
	hand_over(root, mr, vim.list_extend(vim.list_extend({}, changes.added), changes.reopened))
	push(root, mr)
end

local function report(root, task)
	local key = MergeRequest.key(root)
	local mr, token
	local taken = false
	app.store():update(MergeRequest, key, function(m)
		taken = task.take(m)
		mr, token = m, taken and task.token(m)
		return taken
	end)
	if not taken then
		return
	end
	local what = task.what(mr)
	local agent = Review.recipient(app.agents(), root)
	if not agent then
		return vim.notify("gitlab: " .. what .. ", no single agent works in " .. vim.fs.basename(root), vim.log.levels.WARN)
	end
	task.prompt(mr, function(text)
		require("configs.runner").message(agent, text, function(ok)
			if not ok then
				return app.store():update(MergeRequest, key, function(m)
					return task.give_back(m, token)
				end)
			end
			app.store():log(vim.tbl_extend("force", { type = "gitlab", root = root, iid = mr.iid, session = agent.id }, task.log(mr, token)))
			vim.notify(("gitlab: sent %s to %s"):format(what, agent:display_name()))
		end)
	end)
end

local failure = {
	take = function(m)
		return m:take_failure()
	end,
	token = function(m)
		return m.reported_run
	end,
	give_back = function(m, run)
		return m:return_failure(run)
	end,
	what = function(mr)
		return ("the failed pipeline on !%s"):format(mr.iid)
	end,
	prompt = function(mr, send)
		ndjson(mr.root, ("projects/:id/pipelines/%s/jobs?scope=failed&per_page=100"):format(mr.pipeline_id), function(jobs, err)
			if err then
				log().warn("gitlab.jobs.failed", { root = mr.root, pipeline = mr.pipeline_id, error = err })
			end
			send(mr:failure_prompt(jobs or {}))
		end)
	end,
	log = function(mr, run)
		return { event = "pipeline_failed", pipeline = mr.pipeline_id, run = run, count = mr.report_count }
	end,
}

local conflicts = {
	take = function(m)
		return m:take_conflicts()
	end,
	token = function(m)
		return m.conflict_head
	end,
	give_back = function(m, head)
		return m:return_conflicts(head)
	end,
	what = function(mr)
		return ("the merge conflicts on !%s"):format(mr.iid)
	end,
	prompt = function(mr, send)
		send(mr:conflicts_prompt())
	end,
	log = function(mr, head)
		return { event = "merge_conflicts", head = head, target = mr.target_branch, count = mr.conflict_count }
	end,
}

local cleanup = {
	take = function(m)
		return m:take_cleanup()
	end,
	token = function(m)
		return m.cleaned
	end,
	give_back = function(m, iid)
		return m:return_cleanup(iid)
	end,
	what = function(mr)
		return ("the cleanup after merging !%s"):format(mr.iid)
	end,
	prompt = function(mr, send)
		send(mr:cleanup_prompt())
	end,
	log = function(mr)
		return { event = "merged_cleanup", branch = mr.branch, target = mr.target_branch }
	end,
}

local function observe(root, snapshot, discussions)
	local merged = false
	local mr = app.store():update(MergeRequest, MergeRequest.key(root), function(m)
		local before = m.state
		m:observe(snapshot, app.now())
		merged = m:merged_from(before)
		if m.state ~= before then
			log().info("gitlab.mr", { root = root, iid = m.iid, from = before, to = m.state })
		end
	end)
	if merged then
		app.store():remove(DiffProgress, DiffProgress.key(root))
		report(root, cleanup)
	end
	if mr:is_live() then
		sync(root, mr, discussions)
	end
	if mr:failure_to_report() then
		report(root, failure)
	end
	if mr:conflicts_to_report() then
		report(root, conflicts)
	end
end

function M.check(root, branch)
	local project = project_of(root)
	local claimed = false
	app.store():update(MergeRequest, MergeRequest.key(root), function(mr)
		claimed = project ~= nil and mr:claim(root, branch, app.now(), M.code)
		return claimed
	end)
	if not claimed then
		return
	end
	graphql(root, project, branch, function(data, err)
		local found = data and data.project
		if not found then
			return app.store():update(MergeRequest, MergeRequest.key(root), function(mr)
				mr:fail(err or ("gitlab has no project " .. project), app.now())
			end)
		end
		local node = found.mergeRequests and found.mergeRequests.nodes and found.mergeRequests.nodes[1]
		observe(root, MergeRequest.from_graphql(node), MergeRequest.discussions_from_graphql(node))
	end)
end

local function forget_gone()
	for _, cls in ipairs({ MergeRequest, DiffProgress }) do
		for _, record in ipairs(app.store():all(cls)) do
			if record.root and vim.fn.isdirectory(record.root) == 0 then
				app.store():remove(cls, record.id)
			end
		end
	end
end

function M.poll()
	for _, p in ipairs(MergeRequest.watched(app.agents())) do
		if project_of(p.root) then
			M.check(p.root, p.branch)
		end
	end
	forget_gone()
end

function M.watch()
	if vim.fn.executable("glab") == 0 then
		return
	end
	vim.uv.new_timer():start(2000, MergeRequest.tick * 1000, vim.schedule_wrap(M.poll))
end

function M.open(root)
	local mr = M.get(root)
	if not (mr and mr:exists() and mr.url) then
		return vim.notify("no merge request for " .. vim.fs.basename(root or "this folder"), vim.log.levels.INFO)
	end
	vim.ui.open(mr.url)
end

return M
