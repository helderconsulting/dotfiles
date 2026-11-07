local Model = require("workspace.shared.lib.model")
local Review = require("workspace.workflow.domain.review")
local format = require("workspace.shared.lib.format")
local Mandatum = require("workspace.workflow.domain.mandatum")

local MergeRequest = Model.extend({
	kind = "merge_requests",
	fields = { "id", "state", "root", "branch", "iid", "url", "title", "by", "checked_at", "error", "fetching", "pipeline", "merge_status", "pipeline_id", "pipeline_url", "pipeline_run", "reported_run", "reported_id", "report_count", "head_sha", "target_branch", "conflict_head", "conflict_count", "cleaned", "poller" },
	machine = {
		initial = "none",
		states = {
			none = { miss = "none", open = "open", request = "changes", approve = "approved", merge = "merged", close = "closed" },
			open = { miss = "none", open = "open", request = "changes", approve = "approved", merge = "merged", close = "closed" },
			changes = { miss = "none", open = "open", request = "changes", approve = "approved", merge = "merged", close = "closed" },
			approved = { miss = "none", open = "open", request = "changes", approve = "approved", merge = "merged", close = "closed" },
			merged = { miss = "none", open = "open", merge = "merged" },
			closed = { miss = "none", open = "open", close = "closed" },
		},
	},
})

MergeRequest.interval = 60
MergeRequest.tick = 5
MergeRequest.fetch_timeout = 30
MergeRequest.report_limit = 3

local words = setmetatable({
	merged = { "merged", "off" },
	closed = { "closed", "off" },
}, { __index = Review.words })

local live = { open = true, changes = true, approved = true }
local finished = { merged = true }

function MergeRequest.key(root)
	return (root:gsub("/", "%%"))
end

function MergeRequest.for_root(root, branch)
	return MergeRequest:new({ id = MergeRequest.key(root), root = root, branch = branch })
end

function MergeRequest.allows(role)
	return role == nil or role == "decanus"
end

function MergeRequest.watched(agents)
	local seen, list = {}, {}
	for _, a in ipairs(agents or {}) do
		if a.running and a.root and a.branch and MergeRequest.allows(a.role) and not seen[a.root] then
			seen[a.root] = true
			table.insert(list, { root = a.root, branch = a.branch })
		end
	end
	return list
end

function MergeRequest.event_of(snapshot)
	if not snapshot then
		return "miss"
	elseif snapshot.state == "merged" then
		return "merge"
	elseif snapshot.state == "closed" then
		return "close"
	elseif snapshot.requested_by and #snapshot.requested_by > 0 then
		return "request"
	end
	return snapshot.approved and "approve" or "open"
end

local people = { changes = "requested_by", approved = "approved_by" }

local pipelines = {
	success = { "pipeline passed", "ok" },
	failed = { "pipeline failed", "bad" },
	running = { "pipeline running", "busy" },
	pending = { "pipeline pending", "busy" },
	created = { "pipeline pending", "busy" },
	preparing = { "pipeline pending", "busy" },
	waiting_for_resource = { "pipeline pending", "busy" },
	scheduled = { "pipeline scheduled", "busy" },
	manual = { "pipeline manual", "off" },
	canceled = { "pipeline canceled", "off" },
	skipped = { "pipeline skipped", "off" },
}

local merge_words = {
	mergeable = { "ready to merge", "ok" },
	not_approved = { "needs approval", "busy" },
	approvals_syncing = { "needs approval", "busy" },
	discussions_not_resolved = { "threads open", "bad" },
	conflict = { "conflicts", "bad" },
	need_rebase = { "needs rebase", "bad" },
	draft_status = { "draft", "off" },
	blocked_status = { "blocked", "bad" },
	requested_changes = { "changes requested", "bad" },
	jira_association_missing = { "needs jira issue", "bad" },
	external_status_checks = { "status checks pending", "busy" },
}

local unsettled = { checking = true, unchecked = true }

local said_by_state = { changes = { requested_changes = true } }

local addressed_words = { changes = { "changes addressed", "busy" } }
local addressed_merge = { requested_changes = { "awaiting re-review", "busy" } }

function MergeRequest:due(now)
	return self.checked_at == nil or now - self.checked_at >= MergeRequest.interval - 5
end

function MergeRequest:claim(root, branch, now, code)
	if code and self.poller and self.poller > code then
		return false
	end
	if self.branch ~= branch then
		self.checked_at = nil
	end
	if self:is_finished() and self.checked_at then
		return false
	end
	if not self:due(now) then
		return false
	end
	self.root, self.branch, self.checked_at, self.fetching = root, branch, now, now
	self.poller = math.max(self.poller or 0, code or 0)
	return true
end

function MergeRequest.pokes(payload)
	return payload.moment == "after_tool" and Review.publishing(payload.tool_name, payload.tool_input) ~= nil
end

function MergeRequest:poke(root)
	self.root = self.root or root
	self.checked_at = nil
	return true
end

function MergeRequest:activity(now)
	if self.fetching and now - self.fetching < MergeRequest.fetch_timeout then
		return self:is_live() and "fetching comments" or "checking gitlab", "busy"
	elseif self.error then
		return "gitlab failed", "bad"
	elseif self.checked_at and not self:is_finished() and now - self.checked_at > MergeRequest.interval * 3 then
		return "gitlab unchecked for " .. format.duration(now - self.checked_at), "bad"
	end
	return nil
end

function MergeRequest:observe(snapshot, at)
	local event = MergeRequest.event_of(snapshot)
	if not self:transition(event, at) then
		return false
	end
	snapshot = snapshot or {}
	self.iid, self.url, self.title = snapshot.iid, snapshot.web_url, snapshot.title
	self.by = people[self.state] and snapshot[people[self.state]]
	self.pipeline, self.merge_status = snapshot.pipeline, snapshot.merge_status
	self.pipeline_id, self.pipeline_url, self.pipeline_run = snapshot.pipeline_id, snapshot.pipeline_url, snapshot.pipeline_run
	self.head_sha, self.target_branch = snapshot.head_sha, snapshot.target_branch
	if self.merge_status and not self:has_conflicts() and not unsettled[self.merge_status] then
		self.conflict_head, self.conflict_count = nil, nil
	end
	self.error = nil
	self.fetching = nil
	return true
end

function MergeRequest.project_path(remote)
	remote = (remote or ""):gsub("%s+$", "")
	local path = remote:match("^%a[%w+.-]*://[^/]+/(.+)$") or remote:match("^[^/@]+@[^:]+:(.+)$")
	return path and (path:gsub("%.git$", ""):gsub("/$", "")) or nil
end

local function usernames(connection)
	local out = {}
	for _, n in ipairs(connection and connection.nodes or {}) do
		table.insert(out, n.username)
	end
	return out
end

local function lower(s)
	return type(s) == "string" and s:lower() or nil
end

function MergeRequest.from_graphql(node)
	if not node then
		return nil
	end
	local requested = {}
	for _, r in ipairs(node.reviewers and node.reviewers.nodes or {}) do
		if r.mergeRequestInteraction and r.mergeRequestInteraction.reviewState == "REQUESTED_CHANGES" then
			table.insert(requested, r.username)
		end
	end
	local by, p = usernames(node.approvedBy), node.headPipeline
	local host = (node.webUrl or ""):match("^(%a[%w+.-]*://[^/]+)")
	return {
		iid = tonumber(node.iid) or node.iid,
		web_url = node.webUrl,
		title = node.title,
		state = node.state,
		approved = node.approved == true and #by > 0,
		approved_by = by,
		requested_by = requested,
		pipeline = p and lower(p.status),
		pipeline_id = p and tonumber(tostring(p.id):match("(%d+)$")),
		pipeline_url = p and p.path and host and (host .. p.path) or nil,
		pipeline_run = p and (p.finishedAt or p.updatedAt),
		merge_status = lower(node.detailedMergeStatus),
		head_sha = node.diffHeadSha,
		target_branch = node.targetBranch,
	}
end

function MergeRequest.discussions_from_graphql(node)
	local out = {}
	for _, d in ipairs(node and node.discussions and node.discussions.nodes or {}) do
		local notes = {}
		for _, n in ipairs(d.notes and d.notes.nodes or {}) do
			local pos = n.position
			table.insert(notes, {
				system = n.system,
				body = n.body,
				resolvable = n.resolvable,
				resolved = n.resolved,
				author = { username = n.author and n.author.username },
				position = pos and { new_path = pos.newPath, old_path = pos.oldPath, new_line = pos.newLine, old_line = pos.oldLine } or nil,
			})
		end
		table.insert(out, { id = tostring(d.id):match("([^/]+)$"), notes = notes })
	end
	return out
end

local function joined(parts)
	local segments = {}
	for _, part in ipairs(parts) do
		if part[1] and #segments > 0 then
			table.insert(segments, { " · " })
		end
		if part[1] then
			table.insert(segments, part)
		end
	end
	return #segments > 0 and { segments = segments } or nil
end

function MergeRequest:readiness()
	if not self:is_live() then
		return nil
	end
	local said = said_by_state[self.state] or {}
	local merge = not said[self.merge_status] and (self.addressed and addressed_merge[self.merge_status] or self:merge_word()) or {}
	return joined({ self:pipeline_word(), merge })
end

function MergeRequest:merge_word()
	if self:conflicts_reported() then
		return { "conflicts, sent to the agent", "busy" }
	elseif self:gave_up_on_conflicts() then
		return { "conflicts after " .. self.conflict_count .. " tries", "bad" }
	end
	return merge_words[self.merge_status]
end

function MergeRequest:pipeline_word()
	if self:failure_reported() then
		return { "pipeline failed, sent to the agent", "busy" }
	elseif self:gave_up() then
		return { "pipeline failed " .. self.report_count .. " times", "bad" }
	end
	return pipelines[self.pipeline] or {}
end

function MergeRequest:run_key()
	return self.pipeline_id and (tostring(self.pipeline_id) .. "@" .. tostring(self.pipeline_run or "")) or nil
end

function MergeRequest:reports_of_this_pipeline()
	return self.reported_id == self.pipeline_id and (self.report_count or 0) or 0
end

function MergeRequest:failure_reported()
	return self.pipeline == "failed" and self.pipeline_id ~= nil and self.reported_run == self:run_key()
end

function MergeRequest:gave_up()
	return self.pipeline == "failed" and not self:failure_reported() and self:reports_of_this_pipeline() >= MergeRequest.report_limit
end

function MergeRequest:failure_to_report()
	return self:is_live() and self.pipeline == "failed" and self.pipeline_id ~= nil and not self:failure_reported() and not self:gave_up()
end

function MergeRequest:take_failure()
	if not self:failure_to_report() then
		return false
	end
	self.report_count = self:reports_of_this_pipeline() + 1
	self.reported_id, self.reported_run = self.pipeline_id, self:run_key()
	return true
end

function MergeRequest:return_failure(run)
	if self.reported_run ~= run then
		return false
	end
	self.reported_run = nil
	self.report_count = math.max(0, (self.report_count or 1) - 1)
	return true
end

function MergeRequest:is_rerun()
	return self:reports_of_this_pipeline() > 1
end

function MergeRequest:failure_prompt(jobs)
	local again = self:is_rerun() and " again, after it was retried" or ""
	local lines = { ("The pipeline for merge request !%s failed%s: %s"):format(self.iid, again, self.pipeline_url or self.url or "") }
	local blocking = {}
	for _, j in ipairs(jobs or {}) do
		if not j.allow_failure then
			table.insert(blocking, j)
		end
	end
	if #blocking > 0 then
		table.insert(lines, "")
		table.insert(lines, "Failed jobs:")
		for _, j in ipairs(blocking) do
			local reason = j.failure_reason and (", " .. tostring(j.failure_reason):gsub("_", " ")) or ""
			table.insert(lines, ("- %s (stage %s, job %s%s): %s"):format(j.name or "?", j.stage or "?", tostring(j.id or "?"), reason, j.web_url or ""))
		end
	end
	table.insert(lines, "")
	table.insert(lines, "Read the failed jobs' logs (`glab ci trace <job id>` or the GitLab tools), find the cause and fix it on this branch."
		.. " If the failure has nothing to do with this branch, like a flaky test or a runner problem, say so instead of changing code.")
	return table.concat(lines, "\n")
end

function MergeRequest:has_conflicts()
	return self.merge_status == "conflict"
end

function MergeRequest:conflicts_reported()
	return self:has_conflicts() and self.head_sha ~= nil and self.conflict_head == self.head_sha
end

function MergeRequest:gave_up_on_conflicts()
	return self:has_conflicts() and not self:conflicts_reported() and (self.conflict_count or 0) >= MergeRequest.report_limit
end

function MergeRequest:conflicts_to_report()
	return self:is_live() and self:has_conflicts() and self.head_sha ~= nil and not self:conflicts_reported() and not self:gave_up_on_conflicts()
end

function MergeRequest:take_conflicts()
	if not self:conflicts_to_report() then
		return false
	end
	self.conflict_count = (self.conflict_count or 0) + 1
	self.conflict_head = self.head_sha
	return true
end

function MergeRequest:return_conflicts(head)
	if self.conflict_head ~= head then
		return false
	end
	self.conflict_head = nil
	self.conflict_count = math.max(0, (self.conflict_count or 1) - 1)
	return true
end

function MergeRequest:conflicts_prompt()
	local target = self.target_branch or "the target branch"
	local again = (self.conflict_count or 0) > 1 and " still" or ""
	return table.concat({
		("Merge request !%s%s has merge conflicts with %s: %s"):format(self.iid, again, target, self.url or ""),
		"",
		("Fetch origin and merge `origin/%s` into this branch, then resolve the conflicts so both sides' changes survive."):format(target)
			.. " Don't rebase, so the branch doesn't need a force push. Check that it still builds and the tests pass."
			.. " If a conflict needs a decision only I can make, stop and ask instead of guessing.",
	}, "\n")
end

function MergeRequest:merged_from(before)
	return before ~= "merged" and self.state == "merged"
end

function MergeRequest:cleanup_to_report()
	return self.state == "merged" and self.iid ~= nil and self.cleaned ~= self.iid
end

function MergeRequest:take_cleanup()
	if not self:cleanup_to_report() then
		return false
	end
	self.cleaned = self.iid
	return true
end

function MergeRequest:return_cleanup(iid)
	if self.cleaned ~= iid then
		return false
	end
	self.cleaned = nil
	return true
end

function MergeRequest:cleanup_prompt(mandata)
	local target = self.target_branch or "the default branch"
	local branch = self.branch or "the merged branch"
	local root = self.root or "its folder"
	local lines = {
		("Merge request !%s was merged into %s, so `%s` is done: %s"):format(self.iid, target, branch, self.url or ""),
		"",
		("Clean up `%s` in `%s` so the next task starts fresh. First check that folder for work that isn't in the merge:"):format(branch, root)
			.. " changes to tracked files, or commits not on the remote. If there is any, stop and tell me instead of cleaning up.",
		("- If `%s` is a worktree, remove it with `git worktree remove` (leave it first if your session is inside it), then delete the local branch `%s`."):format(root, branch),
		("- If it's the main checkout, switch it to `%s`, pull it, and delete the local branch `%s`."):format(target, branch),
		"Only touch that folder and that branch, not the folder you're working in if that's somewhere else.",
	}
	if mandata and #mandata > 0 then
		table.insert(lines, "")
		table.insert(lines, "These mandata you were sent are still in progress:")
		for _, m in ipairs(mandata) do
			table.insert(lines, ("- %s %s"):format(m.id, m.title))
		end
		table.insert(lines, ("Close each one this merge finishes with `%s done <id> \"<what you did>\"`, and leave the others open."):format(Mandatum.done_command))
	end
	table.insert(lines, "Then wait for the next task.")
	return table.concat(lines, "\n")
end

function MergeRequest:card_lines(now)
	local label, tone = self:label()
	local doing, doing_tone = self:activity(now)
	if not label and doing_tone ~= "bad" then
		return {}
	end
	return { joined({ { label, tone }, { doing, doing_tone } }), self:readiness() }
end

function MergeRequest:fail(reason, at)
	self.error = { reason = reason, at = at }
	self.fetching = nil
end

function MergeRequest:exists()
	return self.state ~= "none" and self.iid ~= nil
end

function MergeRequest:is_finished()
	return finished[self.state] == true
end

function MergeRequest:is_live()
	return live[self.state] == true
end

function MergeRequest:hydrate(parts)
	self.addressed = parts.addressed == true
	return self
end

function MergeRequest:label()
	local word = self:exists() and (self.addressed and addressed_words[self.state] or words[self.state])
	if not word then
		return nil
	end
	local text = "!" .. self.iid .. " " .. word[1]
	if self.by and #self.by > 0 then
		text = text .. (self.addressed and " for " or " by ") .. table.concat(self.by, ", ")
	end
	return text, word[2]
end

local function author_of(note)
	return note.author and note.author.username or "someone"
end

function MergeRequest.threads(discussions)
	local out = {}
	for _, d in ipairs(discussions or {}) do
		local notes = {}
		for _, n in ipairs(d.notes or {}) do
			if not n.system then
				table.insert(notes, n)
			end
		end
		local first = notes[1]
		if first and first.resolvable then
			local resolved = true
			local lines = {}
			for _, n in ipairs(notes) do
				resolved = resolved and n.resolved == true
				table.insert(lines, "@" .. author_of(n) .. ": " .. (n.body or ""))
			end
			local pos = type(first.position) == "table" and first.position or {}
			table.insert(out, {
				id = d.id,
				resolved = resolved,
				author = author_of(first),
				path = pos.new_path or pos.old_path,
				line = pos.new_line or pos.old_line,
				text = table.concat(lines, "\n\n"),
				notes = #notes,
			})
		end
	end
	return out
end

return MergeRequest
