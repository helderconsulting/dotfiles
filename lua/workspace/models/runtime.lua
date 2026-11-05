local Model = require("workspace.model")

local Runtime = Model.extend({
	kind = "runtimes",
	fields = { "id", "state", "provider", "model", "reason", "since", "context", "mode" },
	machine = {
		initial = "checking",
		states = {
			checking = { verify = "sdk", reject = "cli", lose = "cli", fall_back = "cli" },
			sdk = { verify = "sdk", reject = "cli", lose = "cli" },
			cli = { verify = "sdk", reject = "cli", lose = "cli", fall_back = "cli" },
		},
	},
})

local warns = { reject = true, fall_back = true }

Runtime.default_provider = "claude"

function Runtime.for_agent(id, provider)
	return Runtime:new({ id = id, provider = provider or Runtime.default_provider })
end

function Runtime:observe(report, at)
	self.provider = report.provider or self.provider
	self.model = report.model or self.model
	self.mode = report.mode or self.mode
	if report.event == "context" then
		self.context = { used = report.used, window = report.window }
		return true
	end
	if report.event == "model" or report.event == "mode" then
		return true
	end
	if not self:transition(report.event, at) then
		return false
	end
	self.since = at
	self.reason = warns[report.event] and report.reason or nil
	return true
end

function Runtime:channel()
	return self.state == "sdk" and "sdk" or nil
end

function Runtime:warning()
	return self.state == "cli" and self.reason or nil
end

function Runtime:context_fraction()
	local c = self.context
	return c and c.window and c.window > 0 and math.min(1, (c.used or 0) / c.window) or nil
end

Runtime.default_mode = "auto"

Runtime.modes = {
	{ value = "auto", description = "approves safe actions itself, asks for the rest" },
	{ value = "default", description = "asks before edits and commands" },
	{ value = "acceptEdits", description = "edits without asking, asks for commands" },
	{ value = "plan", description = "plans first and changes nothing until you approve" },
	{ value = "dontAsk", description = "never asks, refuses what it would have asked for" },
}

function Runtime:mode_label()
	return self.mode and self.mode ~= Runtime.default_mode and self.mode or nil
end

function Runtime:model_label()
	return self.model and (self.model:match("^claude%-(%a+)") or self.model) or nil
end

return Runtime
