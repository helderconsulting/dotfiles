local Model = require("workspace.shared.lib.model")
local mandatum_request = require("workspace.conversations.domain.mandatum_request")

local Question = Model.extend({
	kind = "asks",
	fields = {
		"id",
		"state",
		"session",
		"kind",
		"event",
		"tool",
		"input",
		"suggestions",
		"cwd",
		"pid",
		"created",
		"decision",
		"answers",
		"output",
		"source",
	},
	machine = {
		initial = "pending",
		states = {
			pending = { show = "shown", answer = "answered", dismiss = "dismissed", expire = "expired" },
			shown = { answer = "answered", dismiss = "dismissed", expire = "expired" },
		},
	},
})

Question.timeout = 580
Question.show_within = 3

local decision_words =
	{ terminal = "answered in the terminal", deny = "denied", always = "always allowed", allow = "allowed" }

function Question.from_session_event(payload, id, pid, at)
	local question = payload.tool_name == "AskUserQuestion"
	return Question:new({
		id = id,
		session = payload.session_id,
		kind = question and "question" or "permission",
		event = payload.moment,
		tool = payload.tool_name,
		input = payload.tool_input or {},
		suggestions = payload.suggestions or {},
		cwd = payload.cwd,
		pid = pid,
		created = at,
	})
end

function Question.from_sdk(req, id, at)
	return Question:new({
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

function Question.handles(payload, headless)
	local question = payload.tool_name == "AskUserQuestion"
	if payload.moment == "before_tool" then
		return question
	end
	return payload.moment == "permission" and (headless or not question)
end

local superseding = { prompt = true, stop = true, ["end"] = true }

function Question.superseded_by(event)
	return superseding[event] == true
end

function Question.next_pending(asks, agents, now, alive)
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

function Question:is_pending()
	return self.state == "pending" or self.state == "shown"
end

function Question:is_unseen()
	return self.state == "pending"
end

function Question:show(at)
	return self:transition("show", at)
end

function Question:is_question()
	return self.kind == "question"
end

function Question:questions()
	return (self.input or {}).questions or {}
end

function Question:rule()
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

function Question:permission_choices()
	local choices = { { key = "y", label = "allow", decision = "allow" } }
	local always = self:rule()
	if always then
		table.insert(choices, { key = "a", label = "always allow", extra = "  " .. always, decision = "always" })
	end
	table.insert(choices, { key = "n", label = "deny", decision = "deny" })
	return choices
end

function Question:details()
	local input = self.input or {}
	local lines
	local request = self.tool == "Bash" and mandatum_request.parse(input.command)
	if request then
		lines = mandatum_request.lines(request)
	elseif self.tool == "Bash" then
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

function Question:summary()
	local input = self.input or {}
	if self:is_question() then
		local q = input.questions and input.questions[1]
		return q and q.question or "a question"
	end
	local what = input.command or input.file_path or input.url or input.pattern or (input.plan and "plan") or ""
	return tostring(self.tool) .. (what ~= "" and (": " .. what) or "")
end

function Question:decide(decision, at)
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

function Question:answer(answers, at)
	local input = {}
	for k, v in pairs(self.input or {}) do
		input[k] = v
	end
	input.answers = answers
	self.decision, self.answers = "answered", answers
	if self.event == "permission" then
		self.output = {
			hookSpecificOutput = {
				hookEventName = "PermissionRequest",
				decision = { behavior = "allow", updatedInput = input },
			},
		}
	else
		self.output = {
			hookSpecificOutput = { hookEventName = "PreToolUse", permissionDecision = "allow", updatedInput = input },
		}
	end
	return self:transition("answer", at)
end

function Question:dismiss(at)
	self.decision = "terminal"
	return self:transition("dismiss", at)
end

function Question:expire(at)
	return self:transition("expire", at)
end

function Question:is_stale(now, alive)
	if self.source == "sdk" then
		return false
	end
	return self:is_pending() and (not alive or now - (self.created or now) > Question.timeout)
end

function Question:result()
	if self.state ~= "answered" then
		return {
			behavior = "deny",
			message = self.state == "dismissed" and "The request was withdrawn." or "Nobody answered this.",
		}
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

function Question:answer_text()
	if decision_words[self.decision or ""] then
		return decision_words[self.decision]
	end
	local list = {}
	for _, q in ipairs(self:questions()) do
		table.insert(list, (self.answers or {})[q.question])
	end
	return table.concat(list, " · ")
end

return Question
