local MergeRequest = require("workspace.workflow.domain.merge_request")
local ImportRemoteCommentsCommand = require("workspace.workflow.application.commands.import_remote_comments_command")
local MarkPushedCommand = require("workspace.workflow.application.commands.mark_pushed_command")
local SendCommentsCommand = require("workspace.workflow.application.commands.send_comments_command")
local MergeRequestDto = require("workspace.workflow.application.dto.merge_request_dto")

local MergeRequestProcess = {}
MergeRequestProcess.__index = MergeRequestProcess

local M = {}

function M.new(ports)
	return setmetatable({
		merge_requests = ports.merge_requests,
		diff_progress = ports.diff_progress,
		gitlab = ports.gitlab,
		remotes = ports.remotes,
		reviews = ports.reviews,
		mandata = ports.mandata,
		agents = ports.agents,
		messenger = ports.messenger,
		quote = ports.quote,
		folders = ports.folders,
		notify = ports.notify,
		logger = ports.logger,
		log = ports.log or function() end,
		clock = ports.clock or os.time,
		code = ports.code or 0,
		interval = ports.interval or MergeRequest.tick,
		projects = {},
	}, MergeRequestProcess)
end

function MergeRequestProcess.pokes(payload)
	return MergeRequest.pokes(payload)
end

function MergeRequestProcess.allows(role)
	return MergeRequest.allows(role)
end


function MergeRequestProcess:poke(root)
	self.merge_requests:update(root, function(m)
		return m:poke(root)
	end)
end

function MergeRequestProcess:available()
	return self.gitlab:available()
end

function MergeRequestProcess:project_of(root)
	if self.projects[root] == nil then
		local url = self.remotes:url(root)
		self.projects[root] = url:match("gitlab") and MergeRequest.project_path(url) or false
	end
	return self.projects[root] or nil
end

function MergeRequestProcess:hydrated(root)
	local mr = root and self.merge_requests:get(root)
	return mr and mr:hydrate({ addressed = self.reviews:addresses(root, mr.iid) }) or nil
end

function MergeRequestProcess:summary(root)
	local mr = self:hydrated(root)
	if not mr then
		return nil
	end
	local label, tone = mr:label()
	return MergeRequestDto.new({
		root = root,
		iid = mr.iid,
		url = mr.url,
		exists = mr:exists(),
		label = label,
		tone = tone,
		card_lines = mr:card_lines(self.clock()),
	})
end

function MergeRequestProcess:url_of(root)
	local mr = self:hydrated(root)
	return mr and mr:exists() and mr.url or nil
end

function MergeRequestProcess:hand_over(root, mr, list)
	if #list == 0 then
		return
	end
	local agent = self.reviews:recipient(root)
	local what = ("%d GitLab comment%s on !%s"):format(#list, #list == 1 and "" or "s", mr.iid)
	if not agent then
		return self.notify.info("review: " .. what .. " saved as drafts, no single agent works in " .. vim.fs.basename(root) .. ". Send with <leader>rs")
	end
	local ids = {}
	for i, c in ipairs(list) do
		ids[i] = c.id
	end
	self.reviews:send_comments(SendCommentsCommand.new({ root = root, ids = ids, agent_id = agent.id, quote = self.quote }), function(ok)
		if ok then
			self.notify.info(("review: sent %s to %s"):format(what, agent.name))
		end
	end)
end

function MergeRequestProcess:push(root, mr)
	for _, c in ipairs(self.reviews:unpushed(root, mr.iid)) do
		local body = c.reply ~= "" and c.reply or "Done."
		self.gitlab:reply(root, mr.iid, c.remote.thread, body, function(err)
			if err then
				return self.logger.warn("gitlab.reply.failed", { root = root, id = c.id, error = err })
			end
			self.gitlab:resolve(root, mr.iid, c.remote.thread, function(rerr)
				if rerr then
					self.logger.warn("gitlab.resolve.failed", { root = root, id = c.id, error = rerr })
				end
				self.reviews:mark_pushed(MarkPushedCommand.new({ root = root, id = c.id, notes = (c.remote.notes or 0) + 1 }))
			end)
		end)
	end
end

function MergeRequestProcess:sync(root, mr, discussions)
	local threads = MergeRequest.threads(discussions)
	local changes = self.reviews:import_remote(ImportRemoteCommentsCommand.new({ root = root, threads = threads, iid = mr.iid }))
	local list = {}
	for _, c in ipairs(changes.added) do
		table.insert(list, c)
	end
	for _, c in ipairs(changes.reopened) do
		table.insert(list, c)
	end
	self:hand_over(root, mr, list)
	self:push(root, mr)
end

function MergeRequestProcess:report(root, task)
	local mr, token
	local taken = false
	self.merge_requests:update(root, function(m)
		taken = task.take(m)
		mr, token = m, taken and task.token(m)
		return taken
	end)
	if not taken then
		return
	end
	local what = task.what(mr)
	local found = self.reviews:recipient(root)
	local agent = found and self.agents:get(found.id)
	if not agent then
		return self.notify.warn("gitlab: " .. what .. ", no single agent works in " .. vim.fs.basename(root))
	end
	task.prompt(self, mr, agent, function(text)
		self.messenger.message(agent.id, text, function(ok)
			if not ok then
				return self.merge_requests:update(root, function(m)
					return task.give_back(m, token)
				end)
			end
			self.log(vim.tbl_extend("force", { type = "gitlab", root = root, iid = mr.iid, session = agent.id }, task.log(mr, token)))
			self.notify.info(("gitlab: sent %s to %s"):format(what, agent.name))
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
	prompt = function(self, mr, _, send)
		self.gitlab:failed_jobs(mr.root, mr.pipeline_id, function(jobs, err)
			if err then
				self.logger.warn("gitlab.jobs.failed", { root = mr.root, pipeline = mr.pipeline_id, error = err })
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
	prompt = function(_, mr, _, send)
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
	prompt = function(self, mr, agent, send)
		send(mr:cleanup_prompt(self.mandata:in_progress_for(agent.id)))
	end,
	log = function(mr)
		return { event = "merged_cleanup", branch = mr.branch, target = mr.target_branch }
	end,
}

function MergeRequestProcess:observe(root, snapshot, discussions)
	local merged = false
	local mr = self.merge_requests:update(root, function(m)
		local before = m.state
		m:observe(snapshot, self.clock())
		merged = m:merged_from(before)
		if m.state ~= before then
			self.logger.info("gitlab.mr", { root = root, iid = m.iid, from = before, to = m.state })
		end
	end)
	if merged then
		self.diff_progress:remove(root)
		self:report(root, cleanup)
	end
	if mr:is_live() then
		self:sync(root, mr, discussions)
	end
	if mr:failure_to_report() then
		self:report(root, failure)
	end
	if mr:conflicts_to_report() then
		self:report(root, conflicts)
	end
end

function MergeRequestProcess:check(root, branch)
	local project = self:project_of(root)
	local claimed = false
	self.merge_requests:update(root, function(mr)
		claimed = project ~= nil and mr:claim(root, branch, self.clock(), self.code)
		return claimed
	end)
	if not claimed then
		return
	end
	self.gitlab:merge_request(root, project, branch, function(found, err)
		if not found then
			return self.merge_requests:update(root, function(mr)
				mr:fail(err, self.clock())
			end)
		end
		self:observe(root, MergeRequest.from_graphql(found.node), MergeRequest.discussions_from_graphql(found.node))
	end)
end

function MergeRequestProcess:forget_gone()
	for _, mr in ipairs(self.merge_requests:all()) do
		if mr.root and not self.folders.exists(mr.root) then
			self.merge_requests:remove(mr.root)
		end
	end
	for _, progress in ipairs(self.diff_progress:all()) do
		if progress.root and not self.folders.exists(progress.root) then
			self.diff_progress:remove(progress.root)
		end
	end
end

function MergeRequestProcess:poll(agents)
	for _, p in ipairs(MergeRequest.watched(agents)) do
		if self:project_of(p.root) then
			self:check(p.root, p.branch)
		end
	end
	self:forget_gone()
end

M.poll = MergeRequestProcess.poll

return M
