local MessageMilesCommand = require("workspace.legio.application.commands.message_miles_command")

local M = {}

local function loaded_at(path)
	local st = path and vim and vim.uv.fs_stat(path)
	return st and st.mtime.sec or 0
end

local function poller_code()
	return math.max(
		loaded_at(package.searchpath("workspace.workflow.infrastructure.outbound.gitlab", package.path)),
		loaded_at(package.searchpath("workspace.workflow.domain.merge_request", package.path)),
		loaded_at(package.searchpath("workspace.workflow.application.merge_request_process", package.path))
	)
end

local notify = {
	info = function(text)
		vim.notify(text, vim.log.levels.INFO)
	end,
	warn = function(text)
		vim.notify(text, vim.log.levels.WARN)
	end,
}

function M.register(services, store, opts)
	services.mandatum_process = require("workspace.workflow.application.mandatum_process").new({
		expeditiones = require("workspace.workflow.infrastructure.outbound.filesystem.expeditio_repository").new(store),
		git = require("workspace.shared.adapters.git"),
		expand_images = function(text, images)
			return require("workspace.conversations.domain.draft").expand(text, images)
		end,
		log = function(entry)
			store:log(entry)
		end,
		clock = opts.clock,
	})
	services.review_process = require("workspace.workflow.application.review_process").new({
		reviews = require("workspace.workflow.infrastructure.outbound.filesystem.review_repository").new(store),
		agents = require("workspace.legio.composition").miles_port(store),
		messenger = {
			message = function(agent_id, text, done)
				services.miles_runner:message(MessageMilesCommand.new({ miles_id = agent_id, text = text }), done)
			end,
		},
		git = require("workspace.shared.adapters.git"),
		expand_images = function(text, images)
			return require("workspace.conversations.domain.draft").expand(text, images)
		end,
		log = function(entry)
			store:log(entry)
		end,
		clock = opts.clock,
	})
	local filesystem = "workspace.workflow.infrastructure.outbound.filesystem."
	local diff_progress = require(filesystem .. "diff_progress_repository").new(store)
	services.workflow_migration = {
		run = function()
			return require(filesystem .. "expeditio_migration").run(store)
		end,
	}
	services.diff_progress_process = require("workspace.workflow.application.diff_progress_process").new({ progress = diff_progress })
	services.merge_request_process = require("workspace.workflow.application.merge_request_process").new({
		merge_requests = require(filesystem .. "merge_request_repository").new(store),
		diff_progress = diff_progress,
		gitlab = require("workspace.workflow.infrastructure.outbound.gitlab").new(),
		remotes = require("workspace.workflow.infrastructure.outbound.git_remote").new(),
		reviews = services.review_process,
		mandata = services.mandatum_process,
		agents = {
			get = function(_, id)
				return services.roster:get(id)
			end,
		},
		messenger = {
			message = function(agent_id, text, done)
				services.miles_runner:message(MessageMilesCommand.new({ miles_id = agent_id, text = text }), done)
			end,
		},
		quote = function(c)
			return require(filesystem .. "file_quote").lines(c.key, c.line1, c.line2)
		end,
		folders = {
			exists = function(path)
				return vim.fn.isdirectory(path) == 1
			end,
		},
		notify = notify,
		logger = store.logger,
		log = function(entry)
			store:log(entry)
		end,
		clock = opts.clock,
		code = poller_code(),
	})
end

return M
