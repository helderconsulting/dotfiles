local Model = require("workspace.model")

local Resource = Model.extend({
	kind = "resources",
	fields = { "id", "state", "word", "tone", "since" },
	machine = {
		initial = "off",
		states = {
			off = { start = "starting", up = "running", fail = "failed", down = "off", busy = "off" },
			starting = { up = "running", fail = "failed", timeout = "failed", down = "starting", busy = "starting" },
			running = { stop = "stopping", up = "running", down = "off", fail = "failed", busy = "running" },
			stopping = { down = "off", fail = "off", up = "stopping", busy = "stopping", timeout = "failed" },
			failed = { start = "starting", up = "running", down = "off", fail = "failed", busy = "failed" },
		},
	},
})

Resource.timeout = 30

local observed = { ok = "up", off = "down", bad = "fail", busy = "busy" }

function Resource:start(at)
	self.since = at
	return self:transition("start", at)
end

function Resource:stop(at)
	self.since = at
	return self:transition("stop", at)
end

function Resource:toggle(at)
	if self.state == "running" then
		return self:stop(at)
	end
	return self:start(at)
end

function Resource:observe(word, tone, at)
	self.word, self.tone = word, tone
	return self:transition(observed[tone] or "busy", at)
end

function Resource:tick(now)
	if (self.state == "starting" or self.state == "stopping") and now - (self.since or now) > Resource.timeout then
		return self:transition("timeout", now)
	end
	return false
end

function Resource:is_pending()
	return self.state == "starting" or self.state == "stopping"
end

function Resource:label()
	if self:is_pending() then
		return self.state, "busy"
	end
	return self.word or self.state, self.tone or "off"
end

return Resource
