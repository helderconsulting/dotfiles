local Model = require("workspace.model")

local Usage = Model.extend({
	kind = "usage",
	fields = { "id", "windows", "overage", "extra", "updated" },
})

function Usage.for_provider(provider)
	return Usage:new({ id = provider, windows = {} })
end

function Usage:observe(report, at)
	if report.windows then
		self.windows = report.windows
		self.overage = report.overage
		self.extra = report.extra or nil
	end
	self.updated = at
	return true
end

function Usage:tightest()
	local worst
	for _, w in ipairs(self.windows or {}) do
		if not worst or (w.used or 0) > (worst.used or 0) then
			worst = w
		end
	end
	return worst
end

function Usage:plan_label()
	local w = self:tightest()
	return w and ("%s %d%%"):format(w.name, math.floor((w.used or 0) * 100 + 0.5)) or nil
end

return Usage
