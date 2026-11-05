local Model = require("workspace.model")

local Ask = Model.extend({
	kind = "asks",
	fields = { "id", "state", "session", "kind", "event", "tool", "input", "suggestions", "cwd", "pid", "created", "decision", "answers", "output", "source" },
	machine = {
		initial = "pending",
		states = {
			pending = { answer = "answered", dismiss = "dismissed", expire = "expired" },
		},
	},
})

Ask.timeout = 580

local decision_words = { terminal = "answered in the terminal", deny = "denied", always = "always allowed", allow = "allowed" }

function Ask.from_hook(payload, id, pid, at)
	local question = payload.tool_name == "AskUserQuestion"
	return Ask:new({
		id = id,
		session = payload.session_id,
		kind = question and "question" or "permission",
		event = payload.hook_event_name,
		tool = payload.tool_name,
		input = payload.tool_input or {},
		suggestions = payload.permission_suggestions or {},
		cwd = payload.cwd,
		pid = pid,
		created = at,
	})
end

function Ask.from_sdk(req, id, at)
	return Ask:new({
		id = id,
		session = req.session,
		kind = req.tool == "AskUserQuestion" and "question" or "permission",
		event = "canUseTool",
		tool = req.tool,
		input = req.input or {},
		suggestions = req.suggestions or {},
		cwd = req.cwd,
		source = "sdk",
		created = at,
	})
end

function Ask.handles(payload, headless)
	local question = payload.tool_name == "AskUserQuestion"
	if payload.hook_event_name == "PreToolUse" then
		return question
	end
	return payload.hook_event_name == "PermissionRequest" and (headless or not question)
end

local superseding = { prompt = true, stop = true, ["end"] = true }

function Ask.superseded_by(event)
	return superseding[event] == true
end

function Ask.next_pending(asks, agents, now, alive)
	local mine = {}
	for _, a in ipairs(agents) do
		mine[a.id] = true
	end
	local next
	for _, ask in ipairs(asks) do
		if mine[ask.session] and ask:is_pending() and not ask:is_stale(now, ask.pid == nil or alive(ask.pid)) then
			if not next or ask.id < next.id then
				next = ask
			end
		end
	end
	return next
end

function Ask:is_pending()
	return self.state == "pending"
end

function Ask:is_question()
	return self.kind == "question"
end

function Ask:questions()
	return (self.input or {}).questions or {}
end

function Ask:rule()
	local s = self.suggestions and self.suggestions[1]
	if not s then
		return nil
	end
	if s.type == "setMode" then
		return "switch to " .. tostring(s.mode)
	end
	local r = s.rules and s.rules[1]
	if r then
		return r.toolName .. (r.ruleContent and ("(" .. r.ruleContent .. ")") or "")
	end
	return s.type
end

function Ask:permission_choices()
	local choices = { { key = "y", label = "allow", decision = "allow" } }
	local always = self:rule()
	if always then
		table.insert(choices, { key = "a", label = "always allow", extra = "  " .. always, decision = "always" })
	end
	table.insert(choices, { key = "n", label = "deny", decision = "deny" })
	return choices
end

function Ask:details()
	local input = self.input or {}
	local lines
	if self.tool == "Bash" then
		lines = { "$ " .. (input.command or ""), input.description }
	elseif self.tool == "ExitPlanMode" then
		lines = {}
		for line in ((input.plan or "") .. "\n"):gmatch("(.-)\n") do
			table.insert(lines, line)
		end
	else
		local main = input.file_path or input.notebook_path or input.url or input.pattern or input.path or input.query
		lines = { main or "" }
	end
	local out = {}
	for _, line in ipairs(lines) do
		if line and line ~= "" then
			table.insert(out, line)
		end
	end
	return out
end

function Ask:summary()
	local input = self.input or {}
	if self:is_question() then
		local q = input.questions and input.questions[1]
		return q and q.question or "a question"
	end
	local what = input.command or input.file_path or input.url or input.pattern or (input.plan and "plan") or ""
	return tostring(self.tool) .. (what ~= "" and (": " .. what) or "")
end

function Ask:decide(decision, at)
	local body = { behavior = decision == "deny" and "deny" or "allow" }
	if decision == "always" then
		body.updatedPermissions = self.suggestions
	elseif decision == "deny" then
		body.message = "The user denied this."
	end
	self.decision = decision
	self.output = { hookSpecificOutput = { hookEventName = "PermissionRequest", decision = body } }
	return self:transition("answer", at)
end

function Ask:answer(answers, at)
	local input = {}
	for k, v in pairs(self.input or {}) do
		input[k] = v
	end
	input.answers = answers
	self.decision, self.answers = "answered", answers
	if self.event == "PermissionRequest" then
		self.output = { hookSpecificOutput = { hookEventName = "PermissionRequest", decision = { behavior = "allow", updatedInput = input } } }
	else
		self.output = { hookSpecificOutput = { hookEventName = "PreToolUse", permissionDecision = "allow", updatedInput = input } }
	end
	return self:transition("answer", at)
end

function Ask:dismiss(at)
	self.decision = "terminal"
	return self:transition("dismiss", at)
end

function Ask:expire(at)
	return self:transition("expire", at)
end

function Ask:is_stale(now, alive)
	if self.source == "sdk" then
		return false
	end
	return self:is_pending() and (not alive or now - (self.created or now) > Ask.timeout)
end

function Ask:result()
	if self.state ~= "answered" then
		return { behavior = "deny", message = self.state == "dismissed" and "The request was withdrawn." or "Nobody answered this." }
	end
	if self.decision == "deny" then
		return { behavior = "deny", message = "The user denied this." }
	end
	local input = {}
	for k, v in pairs(self.input or {}) do
		input[k] = v
	end
	input.answers = self.answers
	return {
		behavior = "allow",
		updatedInput = input,
		updatedPermissions = self.decision == "always" and self.suggestions or nil,
	}
end

function Ask:answer_text()
	if decision_words[self.decision or ""] then
		return decision_words[self.decision]
	end
	local list = {}
	for _, q in ipairs(self:questions()) do
		table.insert(list, (self.answers or {})[q.question])
	end
	return table.concat(list, " · ")
end

return Ask
