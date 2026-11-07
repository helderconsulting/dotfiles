local Model = require("workspace.shared.lib.model")

local Workspace = Model.extend({
	kind = "workspaces",
	fields = { "id", "tab", "window", "root", "mode", "panes", "opened" },
})

Workspace.roles = { "sidebar", "conversation", "editor", "docker" }
Workspace.sizes = {
	sidebar = { min = 28, ideal = 44 },
	conversation = { min = 32, ideal = 78 },
	editor = { min = 60, share = 0.5 },
	panel = { min = 18, max = 35, share = 0.25 },
	docker = { min = 6, keep = 10 },
}

function Workspace:init()
	self.panes = self.panes or {}
	self.mode = self.mode or "full"
end

function Workspace:wants(role)
	if self.mode == "nvim" then
		return role == "sidebar" or role == "editor"
	end
	return true
end

function Workspace:pane(role)
	return self.panes[role]
end

function Workspace:set_pane(role, id)
	self.panes[role] = id
end

function Workspace:role_of(id)
	for role, pane in pairs(self.panes) do
		if pane == id then
			return role
		end
	end
end

function Workspace:forget(id)
	local role = self:role_of(id)
	if role then
		self.panes[role] = nil
	end
	return role
end

function Workspace:missing(alive, keep_closed)
	local list = {}
	for _, role in ipairs(Workspace.roles) do
		local gone = not (self.panes[role] and alive(self.panes[role]))
		if self:wants(role) and gone and not (keep_closed and self.panes[role]) then
			table.insert(list, role)
		end
	end
	return list
end

local function clamp(value, low, high)
	return math.max(low, math.min(high, value))
end

function Workspace:widths(total)
	local sizes = Workspace.sizes
	local conversation = self:wants("conversation")
	local avail = total - (conversation and 2 or 1)
	local sidebar = sizes.sidebar.ideal
	local conv = conversation and sizes.conversation.ideal or 0
	local floor = math.max(sizes.editor.min, math.floor(total * sizes.editor.share))
	local function short()
		return floor - (avail - sidebar - conv)
	end
	if short() > 0 and conversation then
		conv = math.max(sizes.conversation.min, conv - short())
	end
	if short() > 0 then
		sidebar = math.max(sizes.sidebar.min, sidebar - short())
	end
	if avail - sidebar - conv < sizes.editor.min then
		local mins = sizes.sidebar.min + (conversation and sizes.conversation.min or 0) + sizes.editor.min
		sidebar = math.max(1, math.floor(avail * sizes.sidebar.min / mins))
		conv = conversation and math.max(1, math.floor(avail * sizes.conversation.min / mins)) or 0
	end
	return { sidebar = sidebar, conversation = conversation and conv or nil, editor = avail - sidebar - conv }
end

function Workspace.panel_width(cols)
	local panel = Workspace.sizes.panel
	return clamp(math.floor(cols * panel.share), panel.min, panel.max)
end

function Workspace.diff_layout(cols)
	return cols >= 140 and "side-by-side" or "inline"
end

function Workspace.docker_rows(editor_rows, tab_rows)
	local docker = Workspace.sizes.docker
	local rows = math.floor(editor_rows * (tab_rows >= 50 and 0.35 or 0.3))
	if rows < docker.min or editor_rows - rows - 1 < docker.keep then
		return nil
	end
	return rows
end

function Workspace.launch(mode)
	local resume = mode:match("^session:(.+)$")
	return resume and { resume = resume } or nil
end

Workspace.view_roles = { "sidebar", "conversation", "docker" }

function Workspace.fit(want, room, keep, least)
	local size = math.min(want, room - 1 - (keep or 1))
	if size < (least or 1) then
		return nil
	end
	return size
end

function Workspace.keeps(w, role, pane)
	return w ~= nil and pane ~= nil and w.panes ~= nil and w.panes[role] == pane
end

function Workspace:contains(path)
	local root = self.root or ""
	return root ~= "" and (path == root or path:sub(1, #root + 1) == root .. "/")
end

return Workspace
