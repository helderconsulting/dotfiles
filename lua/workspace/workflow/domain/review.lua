local Model = require("workspace.shared.lib.model")

local Comment = Model.extend({
	kind = "comments",
	fields = { "id", "state", "key", "path", "rev", "line1", "line2", "text", "images", "reply", "created", "sent_at", "resolved_at", "sent_to", "remote" },
	machine = {
		initial = "draft",
		states = {
			draft = { edit = "draft", send = "sent", delete = "deleted" },
			sent = { resolve = "resolved", edit = "draft", delete = "deleted" },
			resolved = { edit = "draft", delete = "deleted" },
		},
	},
})

function Comment:location()
	if not self.line1 then
		return self.path or "?"
	end
	local range = self.line2 and self.line2 ~= self.line1 and ("-" .. self.line2) or ""
	return (self.path or "?") .. ":" .. tostring(self.line1 or "?") .. range
end

function Comment:is_open()
	return self.state == "sent"
end

function Comment:is_draft()
	return self.state == "draft"
end

function Comment:one_line()
	return (self.text or ""):gsub("\n", " ")
end

local Review = Model.extend({
	kind = "reviews",
	fields = { "id", "state", "root", "comments", "ready", "approved", "dismissed" },
	machine = {
		initial = "open",
		states = {
			open = { send = "changes", ready = "ready", approve = "approved" },
			changes = { send = "changes", ready = "ready", approve = "approved" },
			ready = { send = "changes", ready = "ready", approve = "approved" },
			approved = { send = "changes", ready = "ready" },
		},
	},
})

Review.Comment = Comment

Review.words = {
	open = { "open", "busy" },
	changes = { "changes requested", "bad" },
	ready = { "ready for review", "ok" },
	approved = { "approved", "ok" },
}

Review.reply_heading = "On your reply:"
Review.changes_heading = "Review comments on the current changes:"
Review.instructions_lead = "When you have handled a comment"
Review.cli = "~/.config/wezterm/bin/review"

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function lines_of(text)
	local out = {}
	for line in (text .. "\n"):gmatch("(.-)\n") do
		table.insert(out, line)
	end
	return out
end

local function paragraphs_of(text)
	local out, current = {}, {}
	for _, line in ipairs(lines_of(text)) do
		if trim(line) == "" then
			if #current > 0 then
				table.insert(out, current)
				current = {}
			end
		else
			table.insert(current, line)
		end
	end
	if #current > 0 then
		table.insert(out, current)
	end
	return out
end

function Review.parse_prompt(text)
	local paragraphs = paragraphs_of((text or ""):gsub("\r", ""))
	if not (paragraphs[1] and Review.is_heading(trim(paragraphs[1][1]))) then
		return nil
	end
	local parts, last = {}, nil
	for _, lines in ipairs(paragraphs) do
		local first = trim(lines[1])
		if first:sub(1, #Review.instructions_lead) == Review.instructions_lead then
			break
		elseif Review.is_heading(first) then
			table.insert(parts, { heading = first })
			last = nil
		else
			local label = Review.is_label(first) and table.remove(lines, 1) or nil
			local quote = {}
			while lines[1] and lines[1]:match("^>") do
				table.insert(quote, (table.remove(lines, 1):gsub("^> ?", "")))
			end
			local body = table.concat(lines, "\n")
			if last and not label and #quote == 0 then
				last.text = last.text .. "\n\n" .. body
			else
				last = { label = label, quote = quote, text = body }
				table.insert(parts, last)
			end
		end
	end
	return parts
end

function Review.is_heading(line)
	return line == Review.reply_heading or line == Review.changes_heading
end

function Review.is_label(line)
	return line:match("^%[%x+%] %S") ~= nil
end

function Review.key(root)
	return (root:gsub("/", "%%"))
end

function Review:init()
	local list = {}
	for _, c in ipairs(self.comments or {}) do
		table.insert(list, getmetatable(c) == Comment and c or Comment:new(c))
	end
	self.comments = list
end

function Review:take_transitions()
	local list = Model.take_transitions(self)
	for _, c in ipairs(self.comments) do
		for _, t in ipairs(c:take_transitions()) do
			t.item = c.id
			table.insert(list, t)
		end
	end
	for _, t in ipairs(self._removed or {}) do
		table.insert(list, t)
	end
	self._removed = nil
	return list
end

function Review:comment(id)
	for _, c in ipairs(self.comments) do
		if c.id == id then
			return c
		end
	end
end

function Review:new_id(random)
	while true do
		local id = string.format("%04x", random(0, 0xffff))
		if not self:comment(id) then
			return id
		end
	end
end

function Review:add(fields, random, at)
	local c = Comment:new(fields)
	c.id = self:new_id(random)
	c.created = at
	table.insert(self.comments, c)
	return c
end

function Review:edit(id, text, at)
	local c = self:comment(id)
	if not c or not c:transition("edit", at) then
		return nil
	end
	c.text, c.reply, c.sent_at, c.resolved_at = text, nil, nil, nil
	return c
end

function Review:delete(id, at)
	for i, c in ipairs(self.comments) do
		if c.id == id and c:transition("delete", at) then
			table.remove(self.comments, i)
			if c.remote then
				self.dismissed = self.dismissed or {}
				self.dismissed[c.remote.thread] = true
			end
			self._removed = self._removed or {}
			for _, t in ipairs(c:take_transitions()) do
				t.item = c.id
				table.insert(self._removed, t)
			end
			return c
		end
	end
end

function Review:clear()
	for _, c in ipairs(self.comments) do
		if c.remote then
			self.dismissed = self.dismissed or {}
			self.dismissed[c.remote.thread] = true
		end
	end
	self.comments = {}
end

function Review:drafts(filter)
	local list = {}
	for _, c in ipairs(self.comments) do
		if c:is_draft() and (not filter or filter(c)) then
			table.insert(list, c)
		end
	end
	return list
end

function Review:open_comments()
	local list = {}
	for _, c in ipairs(self.comments) do
		if c:is_open() then
			table.insert(list, c)
		end
	end
	return list
end

function Review:send(comments, at, to)
	for _, c in ipairs(comments) do
		c:transition("send", at)
		c.sent_at, c.sent_to = at, to
	end
	if #comments > 0 then
		self.ready, self.approved = nil, nil
		self:transition("send", at)
	end
	return comments
end

function Review:remote_comment(thread)
	for _, c in ipairs(self.comments) do
		if c.remote and c.remote.thread == thread then
			return c
		end
	end
end

function Review:import(threads, iid, random, at)
	local changes = { added = {}, reopened = {}, closed = {} }
	for _, t in ipairs(threads) do
		local c = self:remote_comment(t.id)
		if not c and not t.resolved and not (self.dismissed or {})[t.id] then
			c = self:add({
				key = t.path and (self.root .. "/" .. t.path) or nil,
				path = t.path or ("merge request !" .. iid),
				line1 = t.line,
				line2 = t.line,
				text = t.text,
				remote = { thread = t.id, iid = iid, notes = t.notes, author = t.author },
			}, random, at)
			table.insert(changes.added, c)
		elseif c and t.resolved and c:is_draft() then
			self:delete(c.id, at)
			table.insert(changes.closed, c)
		elseif c and t.resolved and c:is_open() then
			self:resolve(c.id, "resolved on GitLab", at)
			c.remote.pushed = true
			table.insert(changes.closed, c)
		elseif c and not t.resolved and c.state == "resolved" and c.remote.pushed and t.notes > c.remote.notes then
			self:edit(c.id, t.text, at)
			c.remote.notes, c.remote.pushed = t.notes, nil
			table.insert(changes.reopened, c)
		end
	end
	return changes
end

function Review:addresses(iid)
	local any = false
	for _, c in ipairs(self.comments) do
		if c.remote and c.remote.iid == iid then
			if c.state ~= "resolved" then
				return false
			end
			any = true
		end
	end
	return any
end

function Review:unpushed(iid)
	local list = {}
	for _, c in ipairs(self.comments) do
		if c.state == "resolved" and c.remote and c.remote.iid == iid and not c.remote.pushed then
			table.insert(list, c)
		end
	end
	return list
end

function Review:mark_pushed(id, notes)
	local c = self:comment(id)
	if not (c and c.remote and c.state == "resolved") then
		return false
	end
	c.remote.pushed, c.remote.notes = true, notes
	return true
end

local unresolvable = {
	resolved = "is already resolved, the user reopens it by editing it",
	draft = "is still a draft, it wasn't sent",
}

function Review:resolve(id, reply, at, session)
	local c = self:comment(id)
	if not c then
		return nil, "no comment " .. id
	end
	if c.sent_to and session and session ~= "" and c.sent_to ~= session then
		return nil, "comment " .. id .. " was sent to another agent, only that agent resolves it"
	end
	if not c:transition("resolve", at) then
		return nil, "comment " .. id .. " " .. (unresolvable[c.state] or ("is " .. c.state))
	end
	c.reply, c.resolved_at = reply, at
	return c
end

local function ids(list)
	local out = {}
	for _, c in ipairs(list) do
		table.insert(out, c.id)
	end
	return table.concat(out, ", ")
end

function Review:mark_ready(note, session, at)
	local open = self:open_comments()
	if #open > 0 then
		return false, "these review comments are still open: " .. ids(open) .. ". Resolve each one first."
	end
	self:transition("ready", at)
	self.ready = { note = note, at = at, session = session }
	self.approved = nil
	return true
end

function Review:can_approve(busy)
	if #self:drafts() > 0 then
		return false, "send or delete the draft comments first"
	end
	local open = self:open_comments()
	if #open > 0 then
		return false, "comments " .. ids(open) .. " are still open"
	end
	if busy then
		return false, "the agent is still working, approve once it's done"
	end
	return true
end

function Review:approve(session, at, tree, busy)
	local ok, why = self:can_approve(busy)
	if not ok then
		return false, why
	end
	if not self:transition("approve", at) then
		return false, "the review is " .. self.state .. ", not ready"
	end
	self.approved = { at = at, session = session, tree = tree }
	return true
end

local publishing_tools = {
	save_merge_request = function(input)
		return input.merge_request_iid == nil and "open a merge request" or nil
	end,
	accept_merge_request = function()
		return "merge a merge request"
	end,
}

local publishing_commands = {
	{ "^glab%s+mr%s+create", "open a merge request" },
	{ "^glab%s+mr%s+merge", "merge a merge request" },
	{ "^gh%s+pr%s+create", "open a pull request" },
	{ "^gh%s+pr%s+merge", "merge a pull request" },
	{ "^git%s+push%s.*%-o%s*merge_request%.create", "open a merge request" },
	{ "^git%s+push%s.*%-%-push%-option[=%s]merge_request%.create", "open a merge request" },
}

local function command_parts(command)
	local parts = {}
	for part in (";" .. tostring(command or "")):gmatch("[;&|(\n]+%s*([^;&|(\n]*)") do
		table.insert(parts, part)
	end
	return parts
end

local push_flags_with_value = { ["-o"] = true, ["--push-option"] = true, ["--repo"] = true, ["--receive-pack"] = true, ["--exec"] = true }
local push_everything = { ["--all"] = true, ["--mirror"] = true, ["--branches"] = true }

local function push_of(part)
	local rest = part:match("^git%s+push%s*(.*)$") or part:match("^git%s+%-C%s+%S+%s+push%s*(.*)$")
	if not rest then
		return nil
	end
	local positional, everything, skip = {}, false, false
	for word in rest:gmatch("%S+") do
		if skip then
			skip = false
		elseif push_everything[word] then
			everything = true
		elseif push_flags_with_value[word] then
			skip = true
		elseif not word:match("^%-") then
			table.insert(positional, word)
		end
	end
	local targets = {}
	for i = 2, #positional do
		local spec = positional[i]:gsub("^%+", "")
		local dst = spec:match(":(.*)$") or spec
		dst = dst:gsub("^refs/heads/", "")
		table.insert(targets, dst == "HEAD" and true or dst)
	end
	return { targets = targets, everything = everything }
end

function Review.pushes(tool, input)
	if tool ~= "Bash" then
		return nil
	end
	local list = {}
	for _, part in ipairs(command_parts((input or {}).command)) do
		table.insert(list, push_of(part))
	end
	return #list > 0 and list or nil
end

function Review.push_block(tool, input, branch, protected)
	for _, push in ipairs(Review.pushes(tool, input) or {}) do
		local targets = #push.targets > 0 and push.targets or { true }
		if push.everything then
			return "Blocked: pushing every branch would push to a protected branch. Push your feature branch by name."
		end
		for _, target in ipairs(targets) do
			local name = target == true and branch or target
			if name and protected[name] then
				return ("Blocked: pushing straight to %s skips the review. Push a feature branch, and open a merge request once the user approves."):format(name)
			end
		end
	end
	return nil
end

function Review.publishing(tool, input)
	input = input or {}
	if tool == "Bash" then
		for _, part in ipairs(command_parts(input.command)) do
			for _, rule in ipairs(publishing_commands) do
				if part:match(rule[1]) then
					return rule[2]
				end
			end
		end
		return nil
	end
	local name = tostring(tool or ""):match("^mcp__.+__([%w_]+)$")
	local check = name and publishing_tools[name]
	return check and check(input) or nil
end

function Review.guards(payload)
	return payload.moment == "before_tool"
		and (Review.publishing(payload.tool_name, payload.tool_input) ~= nil or Review.pushes(payload.tool_name, payload.tool_input) ~= nil)
end

function Review.for_root(root)
	return Review:new({ id = Review.key(root), root = root })
end

function Review:publish_block(action, tree, command)
	local lead = "Blocked: you can't " .. action .. " until the user has reviewed and approved this code."
	if self.state ~= "approved" then
		return lead .. (" When the work is done, run `%s ready \"<one-line summary>\"` and stop."):format(command)
			.. " The user approves the review in their editor and tells you when to go ahead."
	end
	if self.approved.tree and self.approved.tree ~= tree then
		return "Blocked: the code changed after the user approved it, so you can't " .. action .. " yet."
			.. (" Run `%s ready \"<what changed>\"` and stop until the user approves again."):format(command)
	end
	return nil
end

function Review:guard(payload, ctx, command)
	local reason = Review.push_block(payload.tool_name, payload.tool_input, ctx.branch, ctx.protected or {})
	local action = not reason and Review.publishing(payload.tool_name, payload.tool_input)
	if action then
		reason = self:publish_block(action, ctx.tree(), command)
	end
	return reason and { hookSpecificOutput = { hookEventName = "PreToolUse", permissionDecision = "deny", permissionDecisionReason = reason } } or nil
end

function Review:gate(payload, command)
	local reason = not payload.continuing and self:gate_message(command) or nil
	return reason and { decision = "block", reason = reason } or nil
end

function Review:in_files()
	local list = {}
	for _, c in ipairs(self.comments) do
		if c.key and c.line1 and c.path ~= "answer" then
			table.insert(list, c)
		end
	end
	table.sort(list, function(a, b)
		if a.path ~= b.path then
			return a.path < b.path
		end
		return a.line1 < b.line1
	end)
	return list
end

function Review:by_path()
	local out = {}
	for _, c in ipairs(self:in_files()) do
		out[c.path] = out[c.path] or { draft = 0, sent = 0, resolved = 0 }
		out[c.path][c.state] = out[c.path][c.state] + 1
	end
	return out
end

function Review.step(list, path, line, direction)
	if #list == 0 then
		return nil
	end
	path, line = path or "", line or 0
	if direction > 0 then
		for _, c in ipairs(list) do
			if c.path > path or (c.path == path and c.line1 > line) then
				return c
			end
		end
		return list[1]
	end
	for i = #list, 1, -1 do
		local c = list[i]
		if c.path < path or (c.path == path and c.line1 < line) then
			return c
		end
	end
	return list[#list]
end

function Review.prompt(list, cli, quote, expand)
	local replies, reviews, remote = {}, {}, false
	for _, c in ipairs(list) do
		table.insert(c.path == "answer" and replies or reviews, c)
		remote = remote or c.remote ~= nil
	end
	local function quoted(c, label)
		local block = label and { label } or {}
		for _, l in ipairs(quote(c)) do
			table.insert(block, "> " .. l)
		end
		table.insert(block, expand(c))
		return table.concat(block, "\n")
	end
	local function section(heading, items, label)
		local blocks = { heading }
		for _, c in ipairs(items) do
			table.insert(blocks, quoted(c, label and label(c)))
		end
		return table.concat(blocks, "\n\n")
	end
	local parts = {}
	if #replies > 0 then
		table.insert(parts, section(Review.reply_heading, replies))
	end
	if #reviews == 0 then
		return table.concat(parts, "\n\n")
	end
	table.insert(parts, section(Review.changes_heading, reviews, function(c)
		local origin = c.remote and (" (GitLab !" .. c.remote.iid .. ")") or c.rev and (" (old version at " .. c.rev:sub(1, 12) .. ")") or ""
		return ("[%s] %s"):format(c.id, c:location()) .. origin
	end))
	local lines = {
		Review.instructions_lead .. ", mark it resolved with a one-line note on what you changed:",
		("`%s resolve <id> \"<note>\"`"):format(cli),
	}
	if remote then
		table.insert(lines, "For the GitLab ones, your note is posted as a reply on the merge request thread and the thread is resolved.")
	end
	table.insert(lines, "If you disagree or need input, leave it open and say why.")
	table.insert(lines, ("Once all are handled, mark the work ready for review: `%s ready \"<short summary>\"`"):format(cli))
	table.insert(parts, table.concat(lines, "\n"))
	return table.concat(parts, "\n\n")
end

function Review.recipient(agents, root, preferred)
	local Miles = require("workspace.legio.domain.miles")
	local running = {}
	for _, a in ipairs(agents) do
		if a:is_running() then
			table.insert(running, a)
		end
	end
	local here = Miles.running_in(running, root)
	local exact = vim.tbl_filter(function(a)
		return a.root == root
	end, here)
	if #here == 1 or #exact == 1 then
		return #exact == 1 and exact[1] or here[1], here
	end
	local list = #here > 0 and here or running
	table.sort(list, function(x, y)
		if (x.id == preferred) ~= (y.id == preferred) then
			return x.id == preferred
		end
		return x:display_name() < y:display_name()
	end)
	return nil, list
end

function Review:counts()
	local n = { draft = 0, sent = 0, resolved = 0 }
	for _, c in ipairs(self.comments) do
		n[c.state] = (n[c.state] or 0) + 1
	end
	return n
end

function Review:owned_by(session)
	local mark = self.approved or self.ready
	return mark ~= nil and (not mark.session or mark.session == "" or mark.session == session)
end

function Review:gate_message(command)
	local open = self:open_comments()
	if #open == 0 then
		return nil
	end
	local lines = { "These review comments are still open:" }
	for _, c in ipairs(open) do
		table.insert(lines, ("- [%s] %s  %s"):format(c.id, c:location(), c:one_line()))
	end
	table.insert(lines, "")
	table.insert(lines, ("Reply on each one with `%s resolve <id> \"<what you changed, or why not>\"`."):format(command)
		.. " A reply in the chat alone does not reach the review."
		.. " If one needs the user's input first, ask in the chat and stop.")
	return table.concat(lines, "\n")
end

return Review
