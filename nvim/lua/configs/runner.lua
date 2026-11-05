local app = require("configs.app")
local agentd = require("configs.agentd")
local link = require("configs.link")

local M = {}

M.provider = "claude"
M.cli_models = { "opus", "sonnet", "haiku", "fable" }
M.cli_settle_ms = 400

local function log()
	return app.live().log
end

local function run(cmd, cwd, done)
	log().info("claude.run", { cmd = cmd, cwd = cwd })
	vim.system(cmd, { cwd = cwd, text = true, env = { WEZTERM_PANE = "" } }, function(res)
		vim.schedule(function()
			local out = vim.trim((res.stdout or "") .. "\n" .. (res.stderr or ""))
			if res.code ~= 0 then
				log().error("claude.failed", { cmd = cmd, code = res.code, output = out })
				vim.notify(cmd[1] .. " " .. cmd[2] .. ": " .. out, vim.log.levels.ERROR)
				return done and done(false)
			end
			if done then
				done(true, out)
			end
		end)
	end)
end

local function background(args, cwd, prompt, done)
	if not (cwd and vim.fn.isdirectory(cwd) == 1) then
		vim.notify("can't start an agent: " .. tostring(cwd) .. " is gone", vim.log.levels.WARN)
		return done and done(false)
	end
	local cmd = { "claude" }
	vim.list_extend(cmd, args)
	table.insert(cmd, "--bg")
	if prompt and prompt ~= "" then
		table.insert(cmd, prompt)
	end
	run(cmd, cwd, function(ok, out)
		local short = ok and (out:match("claude attach (%x+)") or out:match("backgrounded · (%x+)"))
		if done then
			done(ok, short)
		end
	end)
end

local function observe(report)
	report.provider = report.provider or M.provider
	require("workspace.agents").record(app.store(), report, app.now())
end

local function launch(cwd, prompt, resume, done, choice)
	if not (cwd and vim.fn.isdirectory(cwd) == 1) then
		vim.notify("can't start an agent: " .. tostring(cwd) .. " is gone", vim.log.levels.WARN)
		return done and done(false)
	end
	choice = choice or {}
	local provider, model, mode = choice.provider or M.provider, choice.model, choice.mode
	agentd.call({ op = "start", provider = provider, id = choice.id, cwd = cwd, prompt = prompt, resume = resume, model = model, mode = mode }, function(ok, res)
		if ok then
			log().info("agent.start", { runtime = "sdk", id = res.id, cwd = cwd })
			return done and done(true, res.id)
		end
		local why = res.error or "agentd failed"
		log().warn("agent.fall_back", { reason = why, code = res.code, cwd = cwd })
		if res.code ~= "plan" then
			observe({ id = resume, provider = provider, event = "fall_back", reason = why })
		end
		if provider ~= "claude" then
			vim.notify(provider .. " needs agentd: " .. why, vim.log.levels.ERROR)
			return done and done(false)
		end
		vim.notify("running on claude --bg instead of the sdk: " .. why, vim.log.levels.WARN)
		local args = resume and { "--resume", resume } or choice.id and { "--session-id", choice.id } or {}
		if model and model ~= "default" then
			vim.list_extend(args, { "--model", model })
		end
		if mode then
			vim.list_extend(args, { "--permission-mode", mode })
		end
		background(args, cwd, prompt, done)
	end)
end

function M.start(cwd, prompt, done, choice)
	launch(cwd, prompt, nil, done, choice)
end

function M.resume(agent_id, cwd, prompt, done)
	launch(cwd, prompt, agent_id, done)
end

local function pane_keys(pane, text, paste, done)
	local cmd = { "wezterm", "cli", "send-text", "--pane-id", tostring(pane) }
	if not paste then
		table.insert(cmd, "--no-paste")
	end
	table.insert(cmd, text)
	vim.system(cmd, { text = true }, vim.schedule_wrap(function(res)
		if res.code ~= 0 then
			vim.notify("couldn't reach the agent's pane: " .. vim.trim(res.stderr or ""), vim.log.levels.ERROR)
		end
		if done then
			done(res.code == 0)
		end
	end))
end

local channels = {
	sdk = {
		send = function(agent, text, done)
			agentd.call({ op = "send", id = agent.id, text = text }, function(ok, res)
				if ok then
					return done(true)
				end
				observe({ id = agent.id, event = "lose", reason = res.error })
				M.resume(agent.id, agent.root or agent.cwd, text, done)
			end)
		end,
		interrupt = function(agent, done)
			agentd.call({ op = "interrupt", id = agent.id }, function(ok)
				done(ok)
			end)
		end,
	},
	pane = {
		send = function(agent, text, done)
			pane_keys(agent.pane, text, true, function(ok)
				if not ok then
					return done(false)
				end
				vim.defer_fn(function()
					pane_keys(agent.pane, "\r", false, done)
				end, 150)
			end)
		end,
		interrupt = function(agent, done)
			pane_keys(agent.pane, "\27", false, function(ok)
				vim.defer_fn(function()
					done(ok)
				end, M.cli_settle_ms)
			end)
		end,
	},
	attach = {
		send = function(agent, text, done)
			link.send(agent.id, text, done)
		end,
		interrupt = function(agent, done)
			link.keys(agent.id, "\27", function(ok)
				vim.defer_fn(function()
					done(ok)
				end, M.cli_settle_ms)
			end)
		end,
	},
}

local function channel(agent)
	return (app.agent(agent.id) or agent):channel()
end

function M.message(agent, text, done)
	agent = app.agent(agent.id) or agent
	if agent:wants_resume() then
		log().info("agent.message.resume", { agent = agent.id, hosted = agent:is_hosted(), length = #text })
		return M.resume(agent.id, agent.root or agent.cwd, text, done)
	end
	local ok, why = agent:can_receive()
	if not ok then
		vim.notify(why, vim.log.levels.WARN)
		return done and done(false)
	end
	log().info("agent.message", { agent = agent.id, channel = channel(agent), pane = agent.pane, length = #text })
	channels[channel(agent)].send(agent, text, function(sent)
		if not sent then
			log().error("agent.message.failed", { agent = agent.id, channel = channel(agent) })
		end
		if sent then
			app.store():update(app.models.Agent, agent.id, function(a)
				a:start_sending(text, app.now())
			end)
		end
		if done then
			done(sent)
		end
	end)
end

M.continue_prompt = "continue"

function M.continue(agent, done)
	M.message(agent, M.continue_prompt, function(sent)
		if sent then
			app.store():update(app.models.Agent, agent.id, function(a)
				return a:continue(app.now())
			end)
		end
		if done then
			done(sent)
		end
	end)
end

function M.hold(agent, text, done)
	app.store():update(app.models.Agent, agent.id, function(a)
		a:hold(text, app.now())
	end)
	log().info("agent.hold", { agent = agent.id, length = #text })
	if done then
		done(true, "held")
	end
end

function M.release(id)
	local out
	app.store():update(app.models.Agent, id, function(a)
		out = a:release()
		return out ~= nil
	end)
	if not out then
		return
	end
	M.message(app.agent(id), out.text, function(sent)
		if not sent then
			app.store():update(app.models.Agent, id, function(a)
				a:hold(out.text, out.at)
			end)
		end
	end)
end

function M.send_now(agent, id)
	local out
	app.store():update(app.models.Agent, agent.id, function(a)
		out = a:take(id)
		return out ~= nil
	end)
	if not out then
		return
	end
	M.interrupt(agent, function()
		M.message(app.agent(agent.id), out.text)
	end)
end

local function cli_gone(id)
	local entry = require("workspace.hooks").registry():entry(id)
	return not (entry and entry.alive)
end

local function when_gone(id, deadline_ms, done)
	if cli_gone(id) then
		return done(true)
	end
	local finished = false
	local watcher, timer = vim.uv.new_fs_event(), vim.uv.new_timer()
	local function finish(ok)
		if finished then
			return
		end
		finished = true
		watcher:close()
		timer:close()
		done(ok)
	end
	watcher:start(app.paths.claude_sessions, {}, vim.schedule_wrap(function()
		if cli_gone(id) then
			finish(true)
		end
	end))
	timer:start(deadline_ms, 0, vim.schedule_wrap(function()
		finish(cli_gone(id))
	end))
end

function M.move_to_sdk(agent, done)
	local id, cwd, held = agent.id, agent.root or agent.cwd, agent:held()
	log().info("agent.move", { agent = id, cwd = cwd })
	link.close(id)
	run({ "claude", "stop", agent:short() }, nil, function(stopped)
		if not stopped then
			return done and done(false, "couldn't stop the cli session")
		end
		when_gone(id, 15000, function(gone)
			if not gone then
				return done and done(false, "the cli session didn't stop")
			end
			M.resume(id, cwd, nil, function(ok)
				if ok then
					app.store():update(app.models.Agent, id, function(a)
						for _, m in ipairs(held) do
							a:hold(m.text, m.at)
						end
						return #held > 0
					end)
				end
				if done then
					done(ok, not ok and "the resume failed" or nil)
				end
			end)
		end)
	end)
end

function M.stop(agent, done)
	app.store():update(app.models.Agent, agent.id, function(a)
		return a:apply("end", app.now())
	end)
	if channel(agent) == "sdk" then
		return agentd.call({ op = "stop", id = agent.id }, function(ok)
			if done then
				done(ok)
			end
		end)
	end
	link.close(agent.id)
	run({ "claude", "stop", agent:short() }, nil, done)
end

function M.interrupt(agent, done)
	channels[channel(agent)].interrupt(agent, done or function() end)
end

function M.set_mode(agent, mode, done)
	if channel(agent) ~= "sdk" then
		return done and done(false)
	end
	agentd.call({ op = "mode", id = agent.id, mode = mode }, function(ok, res)
		if not ok then
			vim.notify("couldn't switch mode: " .. tostring(res.error), vim.log.levels.WARN)
		end
		if done then
			done(ok)
		end
	end)
end

local function cli_catalog()
	return {
		{
			provider = M.provider,
			models = vim.tbl_map(function(m)
				return { value = m, label = m }
			end, M.cli_models),
		},
	}
end

function M.catalog(cwd, done)
	agentd.call({ op = "catalog", cwd = cwd }, function(ok, res)
		done(ok and res.providers or cli_catalog())
	end)
end

function M.current(agent)
	return { provider = agent:provider() or M.provider, model = agent:model_name(), mode = agent:mode() }
end

function M.models(agent, done)
	local provider = M.current(agent).provider
	if channel(agent) ~= "sdk" then
		return done(cli_catalog())
	end
	agentd.call({ op = "models", id = agent.id }, function(ok, res)
		done({ { provider = provider, models = ok and res.models or {} } })
	end)
end

function M.set_model(agent, model, done)
	local function finish(ok)
		if ok then
			observe({ id = agent.id, event = "model", model = model })
		end
		if done then
			done(ok)
		end
	end
	if channel(agent) == "sdk" then
		return agentd.call({ op = "model", id = agent.id, model = model }, function(ok, res)
			if not ok then
				vim.notify("couldn't switch model: " .. tostring(res.error), vim.log.levels.WARN)
			end
			finish(ok)
		end)
	end
	channels[channel(agent)].send(agent, "/model " .. model, finish)
end

function M.deliver(draft, done)
	local agent = draft.target.agent and app.agent(draft.target.agent)
	local how, why = draft:delivery(agent)
	local text = draft:message()
	if how == "todo" or how == "epic" then
		local ok, why = require("configs.todos").save(draft.target, text)
		if not ok then
			vim.notify(why or "couldn't save it", vim.log.levels.WARN)
		end
		return done and done(ok ~= false and ok ~= nil, how)
	elseif how == "message" then
		return M.message(agent, text, done)
	elseif how == "hold" then
		return M.hold(agent, text, done)
	elseif how == "resume" then
		return M.resume(draft.target.agent, draft.target.cwd or (agent and agent.root), text, done)
	elseif how == "start" then
		return M.start(draft.target.cwd, text, done, { provider = draft.target.provider, model = draft.target.model, mode = draft.target.mode })
	end
	vim.notify(why, vim.log.levels.WARN)
	if done then
		done(false)
	end
end

return M
