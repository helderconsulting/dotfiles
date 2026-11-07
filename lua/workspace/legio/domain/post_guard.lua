local Legio = require("workspace.legio.domain.legio")
local MandatumRequest = require("workspace.conversations.domain.mandatum_request")

local M = {}

local writers = { Edit = true, Write = true, NotebookEdit = true, MultiEdit = true }
local editors = { faber = true, probator = true, auxilium = true }
local leaders = { centurio = true, optio = true, decanus = true }

local function leader_reason(post)
	return ("Blocked: as %s you don't edit or write files. Hand the change to the miles who does it with `%s order <name|all> \"<message>\"`."):format(post, Legio.command)
end

local function writing_reason(post, plan_gate_open)
	if editors[post] then
		if post == "faber" and not plan_gate_open then
			return ("Blocked: your decanus's plan isn't approved yet, so you can't edit files. The decanus submits it with `%s plan \"<text>\"`, and the optio approves it with `%s approve <decanus name>`. Wait until then."):format(Legio.command, Legio.command)
		end
		return nil
	end
	if leaders[post] then
		return leader_reason(post)
	end
	if post == "censor" then
		return ("Blocked: as censor you review the code and don't change it. Report what is wrong to your superior with `%s report \"<message>\"`."):format(Legio.command)
	end
	return ("Blocked: your post (%s) may not edit or write files. Hand the change to your faber with `%s order <name|all> \"<message>\"`."):format(tostring(post), Legio.command)
end

local git_refusals = {
	others = "Blocked: only the decanus commits, pushes and manages worktrees; hand it to your decanus.",
	commander = "Blocked: the commander commits in this codebase, and worktrees aren't used here; report your changes with legio report.",
}

local function git_refusal(post, rights)
	if post ~= "decanus" then
		return git_refusals.others
	elseif rights and rights.commander_commits == true then
		return git_refusals.commander
	end
end

local value_options = { ["-C"] = true, ["-c"] = true, ["--git-dir"] = true, ["--work-tree"] = true, ["--namespace"] = true }
local wrappers = { rtk = true, env = true, sudo = true, nohup = true, command = true, exec = true, time = true, xargs = true }
local shells = { sh = true, bash = true, zsh = true, dash = true }
local max_depth = 3

local function base(text)
	return text:match("([^/]+)$") or text
end

local function is_option(text)
	return text:sub(1, 1) == "-"
end

local function subcommand(texts, i)
	while texts[i] and is_option(texts[i]) do
		i = i + (value_options[texts[i]] and 2 or 1)
	end
	local sub = texts[i]
	if sub == "commit" or sub == "push" then
		return sub
	elseif sub == "worktree" and (texts[i + 1] == "add" or texts[i + 1] == "remove") then
		return "worktree " .. texts[i + 1]
	end
end

local git_action

local function skip_prefix(texts, i)
	while texts[i] and (wrappers[base(texts[i])] or is_option(texts[i]) or texts[i]:match("^[%a_][%w_]*=")) do
		i = i + 1
	end
	return i
end

local function shell_code(texts, i)
	local k = i + 1
	while texts[k] and not texts[k]:match("^%-%a*c$") do
		k = k + 1
	end
	return texts[k] and texts[k + 1]
end

local function segments(tokens)
	local out, current = {}, {}
	for _, token in ipairs(tokens) do
		if token.op == "&&" or token.op == "|" then
			table.insert(out, current)
			current = {}
		elseif token.text then
			table.insert(current, token.text)
		end
	end
	table.insert(out, current)
	return out
end

local function action_in(tokens, depth)
	for _, texts in ipairs(segments(tokens)) do
		local i = skip_prefix(texts, 1)
		local first = texts[i] and base(texts[i])
		if first == "git" then
			local action = subcommand(texts, i + 1)
			if action then
				return action
			end
		elseif shells[first] and depth < max_depth then
			local code = shell_code(texts, i)
			local action = code and git_action(code, depth + 1)
			if action then
				return action
			end
		end
	end
end

local function raw_pieces(command)
	local limit = #command
	local heredoc = command:find("<<", 1, true)
	if heredoc then
		limit = (command:find("\n", heredoc, true) or #command + 1) - 1
	end
	local pieces, current, quote, i = {}, {}, nil, 1
	local function cut()
		table.insert(pieces, table.concat(current))
		current = {}
	end
	while i <= limit do
		local c = command:sub(i, i)
		if c == "\\" and quote ~= "'" then
			table.insert(current, command:sub(i, i + 1))
			i = i + 1
		elseif quote then
			if c == quote then
				quote = nil
			end
			table.insert(current, c)
		elseif c == "'" or c == '"' then
			quote = c
			table.insert(current, c)
		elseif c == ";" or c == "|" or c == "&" or c == "\n" then
			cut()
		else
			table.insert(current, c)
		end
		i = i + 1
	end
	cut()
	return pieces
end

local function raw_git_action(command)
	for _, piece in ipairs(raw_pieces(command)) do
		local texts = {}
		for word in piece:gmatch("%S+") do
			table.insert(texts, word)
		end
		local i = skip_prefix(texts, 1)
		if texts[i] and base(texts[i]) == "git" then
			local action = subcommand(texts, i + 1)
			if action then
				return action
			end
		end
	end
end

function git_action(command, depth)
	local tokens = MandatumRequest.words(command)
	if tokens then
		return action_in(tokens, depth or 0)
	end
	return raw_git_action(command)
end

local write_reason = "Blocked: you may not write files from the shell. Hand it to your faber; don't work around this guard."
local sed_flags = { inplace = "^%-[nrEsuz]*i", script = "^%-[nrEsuz]*[ef]" }
local perl_flags = { inplace = "^%-[pnlaF0-9]*i", script = "^%-[pnlaF0-9]*[eE]" }

local function normalize(path)
	local parts = {}
	for part in path:gmatch("[^/]+") do
		if part == ".." then
			table.remove(parts)
		elseif part ~= "." then
			table.insert(parts, part)
		end
	end
	return "/" .. table.concat(parts, "/")
end

local function resolve(target, cwd)
	if type(target) ~= "string" or target:find("[%$`~]") then
		return nil
	elseif target:sub(1, 1) == "/" then
		return normalize(target)
	elseif type(cwd) == "string" and cwd:sub(1, 1) == "/" then
		return normalize(cwd .. "/" .. target)
	end
end

local function inside(path, root)
	if not (path and type(root) == "string" and root:sub(1, 1) == "/") then
		return false
	end
	local r = normalize(root)
	return path == r or path:sub(1, #r + 1) == r .. "/"
end

local function any_inside(targets, cwd, root)
	for _, target in ipairs(targets) do
		if inside(resolve(target, cwd), root) then
			return true
		end
	end
	return false
end

local function redirect_word(command, j)
	while command:sub(j, j) == " " or command:sub(j, j) == "\t" do
		j = j + 1
	end
	local q = command:sub(j, j)
	if q == "'" or q == '"' then
		local close = command:find(q, j + 1, true)
		return close and command:sub(j + 1, close - 1) or nil
	end
	return command:match("^[^%s;|&<>()]+", j)
end

local function redirect_targets(command)
	local out = {}
	local last = #command
	local heredoc = command:find("<<", 1, true)
	if heredoc then
		last = (command:find("\n", heredoc, true) or #command + 1) - 1
	end
	local i, quote = 1, nil
	while i <= last do
		local c = command:sub(i, i)
		if quote then
			if c == quote then
				quote = nil
			elseif c == "\\" and quote == '"' then
				i = i + 1
			end
		elseif c == "'" or c == '"' then
			quote = c
		elseif c == "\\" then
			i = i + 1
		elseif c == ">" then
			local j = i + 1
			if command:sub(j, j) == ">" then
				j = j + 1
			end
			if command:sub(j, j) == "|" then
				j = j + 1
			end
			local duplicate = false
			if command:sub(j, j) == "&" then
				local nxt = command:sub(j + 1, j + 1)
				duplicate = nxt:match("%d") ~= nil or nxt == "-"
				j = j + 1
			end
			local target = not duplicate and redirect_word(command, j) or nil
			if target then
				table.insert(out, target)
			end
		end
		i = i + 1
	end
	return out
end

local function positionals(texts, from)
	local out = {}
	for k = from, #texts do
		if not is_option(texts[k]) then
			table.insert(out, texts[k])
		end
	end
	return out
end

local function in_place(texts, from, flags)
	for k = from, #texts do
		local t = texts[k]
		if t:match(flags.inplace) or t == "--in-place" then
			return true
		end
	end
	return false
end

local function script_arguments(texts, from, flags)
	local files, script = {}, false
	local k = from
	while k <= #texts do
		local t = texts[k]
		if (t:match(flags.script) or t == "--expression" or t == "--file") and not t:find("=", 1, true) then
			script = true
			k = k + 2
		else
			if not is_option(t) then
				table.insert(files, t)
			end
			k = k + 1
		end
	end
	return files, script
end

local function command_writes(texts, cwd, root)
	local i = skip_prefix(texts, 1)
	local cmd = texts[i] and base(texts[i])
	if cmd == "tee" then
		return any_inside(positionals(texts, i + 1), cwd, root)
	elseif cmd == "sed" or cmd == "perl" then
		local flags = cmd == "sed" and sed_flags or perl_flags
		if not in_place(texts, i + 1, flags) then
			return false
		end
		local files, script = script_arguments(texts, i + 1, flags)
		if not script then
			table.remove(files, 1)
		end
		return any_inside(files, cwd, root)
	end
	return false
end

local function command_segments(command)
	local tokens = MandatumRequest.words(command)
	if tokens then
		return segments(tokens)
	end
	local out = {}
	for _, piece in ipairs(raw_pieces(command)) do
		local texts = {}
		for word in piece:gmatch("%S+") do
			table.insert(texts, word)
		end
		table.insert(out, texts)
	end
	return out
end

local function writes_into_root(command, cwd, root)
	if any_inside(redirect_targets(command), cwd, root) then
		return true
	end
	for _, texts in ipairs(command_segments(command)) do
		if command_writes(texts, cwd, root) then
			return true
		end
	end
	return false
end

local commander_flag_reason = "Blocked: only the commander sets who commits; ask the commander."

local function sets_commander_flag(command)
	for _, texts in ipairs(command_segments(command)) do
		local i = skip_prefix(texts, 1)
		if texts[i] and base(texts[i]) == "legio" and texts[i + 1] == "cohors" and texts[i + 2] == "commander-commits" then
			return true
		end
	end
	return false
end

function M.check(post, plan_gate_open, tool_name, tool_input, root, cwd, rights)
	if tool_name == "Bash" then
		local input = type(tool_input) == "table" and tool_input or {}
		local command = type(input.command) == "string" and input.command or ""
		local action = git_action(command, 0)
		if sets_commander_flag(command) then
			return commander_flag_reason
		elseif action then
			return git_refusal(post, rights)
		elseif not editors[post] and writes_into_root(command, cwd, root) then
			return write_reason
		end
		return nil
	elseif writers[tool_name] then
		return writing_reason(post, plan_gate_open)
	end
end

return M
