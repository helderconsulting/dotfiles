local Model = require("workspace.shared.lib.model")

local MilesProcess = Model.extend({
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

MilesProcess.default_provider = require("workspace.shared.providers").current().name

function MilesProcess.for_miles(id, provider)
	return MilesProcess:new({ id = id, provider = provider or MilesProcess.default_provider })
end

function MilesProcess:observe(report, at)
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

function MilesProcess:channel()
	return self.state == "sdk" and "sdk" or nil
end

function MilesProcess:warning()
	return self.state == "cli" and self.reason or nil
end

function MilesProcess:context_fraction()
	local c = self.context
	return c and c.window and c.window > 0 and math.min(1, (c.used or 0) / c.window) or nil
end

MilesProcess.default_mode = "auto"

MilesProcess.modes = {
	{ value = "auto", description = "approves safe actions itself, asks for the rest" },
	{ value = "default", description = "asks before edits and commands" },
	{ value = "acceptEdits", description = "edits without asking, asks for commands" },
	{ value = "plan", description = "plans first and changes nothing until you approve" },
	{ value = "dontAsk", description = "never asks, refuses what it would have asked for" },
}

function MilesProcess:mode_label()
	return self.mode and self.mode ~= MilesProcess.default_mode and self.mode or nil
end

function MilesProcess:model_label()
	return self.model and require("workspace.shared.providers").current().model_label(self.model) or nil
end

return MilesProcess
