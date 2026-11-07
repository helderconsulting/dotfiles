local Model = require("workspace.shared.lib.model")

local AgentdStatus = Model.extend({
	kind = "daemons",
	fields = { "id", "state", "reason", "since" },
	machine = {
		initial = "stopped",
		states = {
			stopped = { launch = "starting", connect = "up", drop = "down", give_up = "failed" },
			starting = { connect = "up", fail = "failed", drop = "down", stop = "stopped" },
			up = { connect = "up", drop = "down", bridge_lost = "degraded", bridge_back = "up", stop = "stopped" },
			degraded = { connect = "degraded", bridge_back = "up", bridge_lost = "degraded", drop = "down", stop = "stopped" },
			down = { launch = "starting", connect = "up", drop = "down", give_up = "failed", stop = "stopped" },
			failed = { launch = "starting", connect = "up", give_up = "failed", stop = "stopped" },
		},
	},
})

AgentdStatus.id = "agentd"

local health = {
	starting = { "starting", "busy" },
	degraded = { "bridge down", "bad" },
	down = { "down", "bad" },
	failed = { "failed", "bad" },
}

function AgentdStatus:observe(event, reason, at)
	if not self:transition(event, at) then
		return false
	end
	self.since = at
	self.reason = reason
	return true
end

function AgentdStatus:health()
	local h = health[self.state]
	if not h then
		return nil
	end
	return h[1], h[2]
end

return AgentdStatus
