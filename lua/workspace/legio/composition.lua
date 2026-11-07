local Roster = require("workspace.legio.application.roster")
local MilesQuestions = require("workspace.legio.application.miles_questions")
local MilesRunner = require("workspace.legio.application.miles_runner")
local MilesSessionEvents = require("workspace.legio.application.miles_session_events")
local ContuberniumMembership = require("workspace.legio.application.contubernium_membership")
local LegioProcess = require("workspace.legio.application.legio_process")
local HandoverProcess = require("workspace.legio.application.handover_process")

local filesystem = "workspace.legio.infrastructure.outbound.filesystem."

local M = {}

local function later(build)
	local value
	return setmetatable({}, {
		__index = function(_, key)
			value = value or build()
			return value[key]
		end,
	})
end

local function module(name)
	return later(function()
		return require(name)
	end)
end

local function repositories(store)
	return {
		milites = require(filesystem .. "miles_repository").new(store),
		processes = require(filesystem .. "miles_process_repository").new(store),
		usages = require(filesystem .. "usage_repository").new(store),
		contubernia = require(filesystem .. "contubernium_repository").new(store),
		legiones = require(filesystem .. "legio_repository").new(store),
		cohortes = require(filesystem .. "cohors_repository").new(store),
		centuriae = require(filesystem .. "centuria_repository").new(store),
		agentd_status = require(filesystem .. "agentd_status_repository").new(store),
		questions = require("workspace.conversations.infrastructure.outbound.filesystem.question_repository").new(store),
	}
end

local function todos(services)
	local Commands = {
		assign = require("workspace.workflow.application.commands.assign_mandatum_command"),
		send = require("workspace.workflow.application.commands.send_mandatum_command"),
		release = require("workspace.workflow.application.commands.release_mandatum_command"),
		hand = require("workspace.workflow.application.commands.hand_mandatum_command"),
	}
	local function mandata()
		return services.mandatum_process
	end
	return {
		done_command = require("workspace.workflow.application.mandatum_process").done_command,
		title = function(id)
			local m = id and mandata():mandatum(id)
			return m and m.title or nil
		end,
		text = function(id)
			local m = id and mandata():mandatum(id)
			return m and m.text or nil
		end,
		assign = function(id, miles)
			return mandata():assign(Commands.assign.new({ mandatum_id = id, miles_id = miles }))
		end,
		send = function(id, miles, assigned_as)
			return mandata():send(Commands.send.new({ mandatum_id = id, miles_id = miles, assigned_as = assigned_as }))
		end,
		release = function(id, miles)
			return mandata():release(Commands.release.new({ mandatum_id = id, miles_id = miles }))
		end,
		reassign = function(id, from, to)
			return mandata():hand(Commands.hand.new({ mandatum_id = id, from = from, to = to }))
		end,
	}
end

local function expeditiones(services)
	local function plain(e)
		if not e then
			return nil
		end
		local mandata = {}
		for _, m in ipairs(e.mandata) do
			table.insert(mandata, { id = m.id, title = m.title, text = m.text, state = m.state, assignee = m.assignee })
		end
		return { id = e.id, title = e.title, root = e.root, mandata = mandata }
	end
	return {
		get = function(id)
			return plain(services.mandatum_process:expeditio(id))
		end,
		of = function(mandatum_id)
			return plain(services.mandatum_process:expeditio_of(mandatum_id))
		end,
	}
end

local function merge_requests(services)
	return {
		pokes = function(payload)
			return services.merge_request_process.pokes(payload)
		end,
		allows = function(role)
			return services.merge_request_process.allows(role)
		end,
		poke = function(root)
			services.merge_request_process:poke(root)
		end,
	}
end

local function reviews(services)
	return {
		check_tool_use = function(payload, cwd)
			return services.review_process:check_tool_use(payload, cwd)
		end,
		check_stop = function(payload, cwd)
			return services.review_process:check_stop(payload, cwd)
		end,
	}
end

local notify = {
	info = function(text)
		vim.notify(text, vim.log.levels.INFO)
	end,
	warn = function(text)
		vim.notify(text, vim.log.levels.WARN)
	end,
	error = function(text)
		vim.notify(text, vim.log.levels.ERROR)
	end,
}

local function pid_alive(pid)
	return pid == nil or vim.uv.kill(pid, 0) == 0
end

local function runner(services, store, repos, clock)
	return MilesRunner.new({
		milites = repos.milites,
		contubernia = repos.contubernia,
		agentd = module("workspace.legio.infrastructure.outbound.agentd_client"),
		cli = later(function()
			return require("workspace.shared.providers").current().background_cli.new(store.logger)
		end),
		attach = require("workspace.shared.providers").current().attach_link,
		panes = module("workspace.legio.infrastructure.outbound.wezterm_panes"),
		sessions = module(filesystem .. "miles_session_repository"),
		report = function(command)
			services.miles_session_events:record_report(command)
		end,
		notify = notify,
		defer = function(fn, ms)
			vim.defer_fn(fn, ms)
		end,
		folder_exists = function(path)
			return vim.fn.isdirectory(path) == 1
		end,
		trace = store.logger,
		clock = clock,
	})
end

local function log_to(store)
	return function(entry)
		store:log(entry)
	end
end

function M.register(services, store, opts)
	local clock = opts.clock or os.time
	local repos = repositories(store)
	local git = module("workspace.shared.adapters.git")
	services.roster = Roster.new({ milites = repos.milites, contubernia = repos.contubernia, agentd_status = repos.agentd_status, todos = todos(services), clock = clock })
	services.miles_runner = runner(services, store, repos, clock)
	services.miles_questions = MilesQuestions.new({
		questions = repos.questions,
		milites = repos.milites,
		viewers = {
			shows_any = function(paths)
				return require("workspace.conversations.application.inquiry").has_viewer(store, paths)
			end,
		},
		log = log_to(store),
		clock = clock,
	})
	services.contubernium_membership = ContuberniumMembership.new({ contubernia = repos.contubernia, milites = repos.milites, todos = todos(services), runner = services.miles_runner, git = git, log = log_to(store), clock = clock })
	services.legio_process = LegioProcess.new({
		legiones = repos.legiones,
		cohortes = repos.cohortes,
		centuriae = repos.centuriae,
		contubernia = repos.contubernia,
		milites = repos.milites,
		runner = services.miles_runner,
		git = git,
		todos = todos(services),
		expeditiones = expeditiones(services),
		handover = {
			hand_over = function(command, done)
				return services.handover_process:hand_over(command, done)
			end,
		},
		log = log_to(store),
		clock = clock,
	})
	services.handover_process = HandoverProcess.new({
		milites = repos.milites,
		contubernia = repos.contubernia,
		centuriae = repos.centuriae,
		cohortes = repos.cohortes,
		legiones = repos.legiones,
		runner = services.miles_runner,
		todos = todos(services),
		log = log_to(store),
		clock = clock,
	})
	services.miles_session_events = MilesSessionEvents.new({
		milites = repos.milites,
		cohortes = repos.cohortes,
		centuriae = repos.centuriae,
		contubernia_records = repos.contubernia,
		legiones = repos.legiones,
		processes = repos.processes,
		usages = repos.usages,
		questions = services.miles_questions,
		contubernia = services.contubernium_membership,
		handover = services.handover_process,
		merge_requests = merge_requests(services),
		reviews = reviews(services),
		git = git,
		sessions = module(filesystem .. "miles_session_repository"),
		pid_alive = pid_alive,
		encode = function(value)
			return vim.json.encode(value)
		end,
		cwd = function()
			return vim.uv.cwd()
		end,
		log = log_to(store),
		clock = clock,
	})
end

function M.miles_port(store)
	local milites = require(filesystem .. "miles_repository").new(store)
	return {
		all = function()
			return milites:all()
		end,
		get = function(id)
			return milites:get(id)
		end,
	}
end

return M
