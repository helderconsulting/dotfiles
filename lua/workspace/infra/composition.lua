local M = {}

local outbound = "workspace.infra.infrastructure.outbound."

local function lazy(name)
	local value
	return setmetatable({}, {
		__index = function(_, key)
			value = value or require(outbound .. name)
			return value[key]
		end,
	})
end

function M.register(services, _, opts)
	local docker = lazy("docker")
	local desktops = lazy("desktops")
	services.resource_process = require("workspace.infra.application.resource_process").new({
		names = { "containers", "images", "volumes", "scripts", "vms", "desktops", "vpn devices", "ports" },
		providers = {
			containers = setmetatable({}, { __index = function(_, key) return docker.containers[key] end }),
			images = setmetatable({}, { __index = function(_, key) return docker.images[key] end }),
			volumes = setmetatable({}, { __index = function(_, key) return docker.volumes[key] end }),
			vms = lazy("vms"),
			desktops = desktops,
			["vpn devices"] = lazy("tailscale"),
			ports = lazy("ports"),
			scripts = lazy("scripts"),
		},
		usage = docker,
		desktops = desktops,
		resources = require("workspace.infra.infrastructure.outbound.memory.resource_repository").new(),
		clock = opts.clock,
	})
end

return M
