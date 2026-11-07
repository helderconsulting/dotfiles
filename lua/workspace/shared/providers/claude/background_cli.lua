local M = {}

M.provider = "claude"
M.label = "claude --bg"
M.models = { "opus", "sonnet", "haiku", "fable" }

function M.new(log)
	local cli = { provider = M.provider, label = M.label, models = M.models }

	local function run(cmd, cwd, done)
		log.info("claude.run", { cmd = cmd, cwd = cwd })
		vim.system(cmd, { cwd = cwd, text = true, env = { WEZTERM_PANE = "" } }, function(res)
			vim.schedule(function()
				local out = vim.trim((res.stdout or "") .. "\n" .. (res.stderr or ""))
				if res.code ~= 0 then
					log.error("claude.failed", { cmd = cmd, code = res.code, output = out })
					vim.notify(cmd[1] .. " " .. cmd[2] .. ": " .. out, vim.log.levels.ERROR)
					return done and done(false)
				end
				if done then
					done(true, out)
				end
			end)
		end)
	end

	function cli.start(args, cwd, prompt, done)
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

	function cli.stop(short, done)
		run({ "claude", "stop", short }, nil, done)
	end

	function cli.launch_args(choice, resume)
		local args = resume and { "--resume", resume } or choice.id and { "--session-id", choice.id } or {}
		if choice.model and choice.model ~= "default" then
			vim.list_extend(args, { "--model", choice.model })
		end
		if choice.mode then
			vim.list_extend(args, { "--permission-mode", choice.mode })
		end
		return args
	end

	return cli
end

return M
