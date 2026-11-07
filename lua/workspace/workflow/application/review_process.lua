local format = require("workspace.shared.lib.format")
local mapper = require("workspace.workflow.application.mappers.review_dto_mapper")
local Review = require("workspace.workflow.domain.review")

local ReviewProcess = {}
ReviewProcess.__index = ReviewProcess

local M = {}

M.protected_branches = { "main", "master" }

function M.new(ports)
	return setmetatable({
		reviews = ports.reviews,
		agents = ports.agents,
		messenger = ports.messenger,
		git = ports.git,
		expand_images = ports.expand_images or function(text)
			return text
		end,
		log = ports.log or function() end,
		clock = ports.clock or os.time,
		random = ports.random or math.random,
		cli = ports.cli or Review.cli,
	}, ReviewProcess)
end

local function append(list, items)
	for _, item in ipairs(items) do
		table.insert(list, item)
	end
	return list
end

local function shell_quote(text)
	return "'" .. text:gsub("'", "'\\''") .. "'"
end

local function set_of(ids)
	local out = {}
	for _, id in ipairs(ids or {}) do
		out[id] = true
	end
	return out
end

function ReviewProcess:summary(root)
	return mapper.to_summary_dto(root and self.reviews:get(root), root)
end

function ReviewProcess:comments(root)
	local r = root and self.reviews:get(root)
	return r and mapper.to_comment_dtos(r.comments, r.root) or {}
end

function ReviewProcess:all_comments()
	local out = {}
	for _, r in ipairs(self.reviews:all()) do
		append(out, mapper.to_comment_dtos(r.comments, r.root))
	end
	return out
end

function ReviewProcess:comments_in_folder(folder)
	local out = {}
	for _, r in ipairs(self.reviews:all()) do
		if format.inside(folder, r.root) then
			append(out, mapper.to_comment_dtos(r.comments, r.root))
		end
	end
	return out
end

function ReviewProcess:draft_comments(root)
	local r = root and self.reviews:get(root)
	return r and mapper.to_comment_dtos(r:drafts(), r.root) or {}
end

function ReviewProcess:open_comments(root)
	local r = root and self.reviews:get(root)
	return r and mapper.to_comment_dtos(r:open_comments(), r.root) or {}
end

function ReviewProcess:comment(root, id)
	local r = root and self.reviews:get(root)
	local c = r and r:comment(id)
	return c and mapper.to_comment_dto(c, r.root) or nil
end

function ReviewProcess:file_counts(root)
	return mapper.to_file_counts_dtos(root and self.reviews:get(root))
end

function ReviewProcess:next_comment(root, path, line, direction)
	local r = root and self.reviews:get(root)
	local list = r and r:in_files() or {}
	local c = Review.step(list, path, line, direction)
	if not c then
		return nil
	end
	for i, item in ipairs(list) do
		if item == c then
			return mapper.to_comment_dto(c, r.root), i, #list
		end
	end
end

function ReviewProcess:prompt_parts(text)
	local parts = Review.parse_prompt(text)
	return parts and mapper.to_prompt_part_dtos(parts) or nil
end

function ReviewProcess:save_comment(command)
	local id
	self.reviews:update(command.root, function(r)
		local now = self.clock()
		if command.id and (command.text or "") == "" then
			return r:delete(command.id, now) ~= nil
		elseif command.id then
			local c = r:edit(command.id, command.text, now)
			if not c then
				return false
			end
			c.images = command.images
			id = command.id
			return true
		elseif (command.text or "") ~= "" then
			id = r:add({ key = command.key, path = command.path, rev = command.rev, line1 = command.line1, line2 = command.line2, text = command.text, images = command.images }, self.random, now).id
			return true
		end
		return false
	end)
	return id
end

function ReviewProcess:delete_comment(command)
	self.reviews:update(command.root, function(r)
		return r:delete(command.id, self.clock()) ~= nil
	end)
end

function ReviewProcess:clear_all()
	for _, review in ipairs(self.reviews:all()) do
		self.reviews:update(review.root, function(r)
			r:clear()
		end)
	end
end

function ReviewProcess:prompt(command)
	local r = self.reviews:get(command.root)
	local wanted = set_of(command.ids)
	local list = {}
	for _, c in ipairs(r and r.comments or {}) do
		if wanted[c.id] then
			table.insert(list, c)
		end
	end
	local cli = ("%s -C %s"):format(self.cli, shell_quote(command.root))
	return Review.prompt(list, cli, function(c)
		return command.quote(mapper.to_comment_dto(c, command.root))
	end, function(c)
		return self.expand_images(c.text, c.images)
	end)
end

function ReviewProcess:recipient(root, preferred)
	local agent, candidates = Review.recipient(self.agents.all(), root, preferred)
	return agent and mapper.to_recipient_dto(agent) or nil, mapper.to_recipient_dtos(candidates)
end

function ReviewProcess:mark_sent(command)
	local wanted = set_of(command.ids)
	local sent = {}
	self.reviews:update(command.root, function(r)
		local now = self.clock()
		local outgoing, answers = {}, {}
		for _, c in ipairs(r.comments) do
			if wanted[c.id] and c:is_draft() then
				local moved = command.lines and command.lines[c.id]
				if moved then
					c.line1, c.line2 = moved[1], moved[2]
				end
				table.insert(c.path == "answer" and answers or outgoing, c)
			end
		end
		for _, c in ipairs(answers) do
			r:delete(c.id, now)
		end
		sent = r:send(outgoing, now, command.agent_id)
		return #answers + #outgoing > 0
	end)
	for _, c in ipairs(sent) do
		self.log({ type = "review", event = "sent", root = command.root, id = c.id, path = c.path, line1 = c.line1, line2 = c.line2, text = c.text, session = command.agent_id, remote = c.remote })
	end
	return #sent
end

function ReviewProcess:send_comments(command, done)
	local text = self:prompt(command)
	self.messenger.message(command.agent_id, text, function(ok)
		if ok then
			self:mark_sent(command)
		end
		if done then
			done(ok)
		end
	end)
end

function ReviewProcess:can_approve(root)
	return self.reviews:get_or_new(root):can_approve()
end

function ReviewProcess:approve(command, done)
	local agent = self.agents.get(command.agent_id)
	local tree = self.git.code_tree(command.root)
	local approved, reason
	self.reviews:update(command.root, function(r)
		approved, reason = r:approve(command.agent_id, self.clock(), tree, agent ~= nil and agent:is_busy())
		return approved
	end)
	if not approved then
		return false, reason
	end
	self.messenger.message(command.agent_id, "Review approved: the changes on this branch are ready for a merge request.", done)
	self.log({ type = "review", event = "approved", root = command.root, session = command.agent_id })
	return true
end

function ReviewProcess:resolve(command)
	local resolved, err
	self.reviews:update(command.root, function(r)
		resolved, err = r:resolve(command.id, command.reply or "", self.clock(), command.session)
		return resolved ~= nil
	end)
	if not resolved then
		return nil, err
	end
	self.log({ type = "review", event = "resolved", root = command.root, id = resolved.id, path = resolved.path, line1 = resolved.line1, line2 = resolved.line2, text = resolved.text, reply = resolved.reply, session = command.session })
	return mapper.to_comment_dto(resolved, command.root)
end

function ReviewProcess:mark_ready(command)
	local ready, why
	self.reviews:update(command.root, function(r)
		ready, why = r:mark_ready(command.note or "", command.session, self.clock())
		return ready
	end)
	if not ready then
		return false, why
	end
	self.log({ type = "review", event = "ready", root = command.root, note = command.note or "", session = command.session })
	return true
end

function ReviewProcess:check_tool_use(payload, cwd)
	if not Review.guards(payload) then
		return nil
	end
	local place = self.git.locate(cwd)
	local protected = set_of(M.protected_branches)
	local default = self.git.default_branch(place.root)
	if default then
		protected[default] = true
	end
	local ctx = {
		branch = place.branch,
		protected = protected,
		tree = function()
			return self.git.code_tree(place.root)
		end,
	}
	return self.reviews:get_or_new(place.root):guard(payload, ctx, self.cli)
end

function ReviewProcess:check_stop(payload, cwd)
	local place = self.git.locate(cwd)
	return self.reviews:get_or_new(place.root):gate(payload, self.cli)
end

function ReviewProcess:import_remote(command)
	local changes
	self.reviews:update(command.root, function(r)
		changes = r:import(command.threads, command.iid, self.random, self.clock())
		return #changes.added + #changes.reopened + #changes.closed > 0
	end)
	return mapper.to_remote_changes_dto(changes, command.root)
end

function ReviewProcess:unpushed(root, iid)
	local r = self.reviews:get(root)
	return r and mapper.to_comment_dtos(r:unpushed(iid), root) or {}
end

function ReviewProcess:mark_pushed(command)
	self.reviews:update(command.root, function(r)
		return r:mark_pushed(command.id, command.notes)
	end)
end

function ReviewProcess:addresses(root, iid)
	local r = root and self.reviews:get(root)
	return r ~= nil and r:addresses(iid)
end

return M
