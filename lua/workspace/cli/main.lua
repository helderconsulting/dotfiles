local base = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0]))))
package.path = base .. "/?.lua;" .. base .. "/?/init.lua;" .. package.path

local commands = {
	["session-event"] = "workspace.legio.infrastructure.inbound.session_event_cli",
	bridge = "workspace.legio.infrastructure.inbound.agentd_bridge",
	contubernium = "workspace.legio.infrastructure.inbound.contubernium_cli",
	legio = "workspace.legio.infrastructure.inbound.legio_cli",
	title = "workspace.legio.infrastructure.inbound.title_cli",
	todo = "workspace.workflow.infrastructure.inbound.mandatum_cli",
	mandatum = "workspace.workflow.infrastructure.inbound.mandatum_cli",
	["migrate-workflow"] = "workspace.workflow.infrastructure.inbound.migrate_cli",
	review = "workspace.workflow.infrastructure.inbound.review_cli",
}

local command = table.remove(arg, 1)
local module = commands[command or ""]
if not module then
	vim.uv.fs_write(2, "workspace: unknown command " .. tostring(command) .. "\n")
	os.exit(2)
end
os.exit(require(module).run(arg) or 0)
