local Model = require("workspace.shared.lib.model")

local SidebarScreen = Model.extend({
	kind = "sidebar_screens",
	fields = { "id", "section", "sections" },
})

function SidebarScreen:report_sections(sections, current)
	self.sections, self.section = sections, current
end

return SidebarScreen
