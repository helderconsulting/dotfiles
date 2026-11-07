local M = {}

local globs = { ["*"] = true, ["?"] = true, ["["] = true, ["]"] = true, ["{"] = true, ["}"] = true }
local refused = { [";"] = true, ["&"] = true, ["<"] = true, [">"] = true, ["("] = true, [")"] = true, ["`"] = true, ["$"] = true, ["\n"] = true, ["!"] = true, ["#"] = true, ["|"] = true }

local function words(command)
	local out, word, quote, tilde = {}, nil, nil, false
	local function flush()
		if word then
			table.insert(out, { text = word, tilde = tilde })
			word, tilde = nil, false
		end
	end
	local i = 1
	while i <= #command do
		local c = command:sub(i, i)
		if quote == "'" then
			if c == "'" then
				quote = nil
			else
				word = word .. c
			end
		elseif quote == '"' then
			local nxt = command:sub(i + 1, i + 1)
			if c == '"' then
				quote = nil
			elseif c == "`" or c == "$" then
				return nil
			elseif c == "\\" and nxt == "\n" then
				return nil
			elseif c == "\\" and (nxt == "\\" or nxt == '"') then
				i = i + 1
				word = word .. nxt
			else
				word = word .. c
			end
		elseif c == "'" or c == '"' then
			quote, word = c, word or ""
		elseif c:match("[ \t]") then
			flush()
		elseif not word and command:sub(i, i + 3) == "2>&1" and command:sub(i + 4, i + 4):match("^[ \t]?$") then
			table.insert(out, { op = "2>&1" })
			i = i + 3
		elseif not word and command:sub(i, i + 1) == "&&" then
			flush()
			table.insert(out, { op = "&&" })
			i = i + 1
		elseif c == "|" and command:sub(i + 1, i + 1) ~= "|" then
			flush()
			table.insert(out, { op = "|" })
		elseif c == "~" and not word then
			word, tilde = "~", true
		elseif globs[c] or refused[c] then
			return nil
		elseif c == "\\" then
			if command:sub(i + 1, i + 1) == "\n" then
				return nil
			end
			i = i + 1
			word = (word or "") .. command:sub(i, i)
		else
			word = (word or "") .. c
		end
		i = i + 1
	end
	if quote then
		return nil
	end
	flush()
	return out
end

function M.words(command)
	if type(command) ~= "string" then
		return nil
	end
	return words(command)
end

local fields = { ["--description"] = "description", ["--epic"] = "expeditio", ["--expeditio"] = "expeditio" }

local function installed(path, name)
	local home = os.getenv("HOME")
	local bin = "/.config/wezterm/bin/" .. name
	return path == name or path == "~" .. bin or (home ~= nil and home ~= "" and path == home .. bin)
end

local function is_add_tool(path)
	return installed(path, "todo") or installed(path, "mandatum")
end

local function plain(token)
	return token and token.text ~= nil and not token.tilde
end

local function trailing_ok(tokens, i)
	if tokens[i] and tokens[i].op == "2>&1" then
		i = i + 1
	end
	local token = tokens[i]
	if not token then
		return true
	end
	if token.op ~= "|" then
		return false
	end
	local filter = tokens[i + 1]
	if not (plain(filter) and (filter.text == "head" or filter.text == "tail")) then
		return false
	end
	for j = i + 2, #tokens do
		if not plain(tokens[j]) then
			return false
		end
	end
	return true
end

function M.parse(command)
	if type(command) ~= "string" then
		return nil
	end
	local tokens = words(command)
	if not tokens or #tokens == 0 then
		return nil
	end
	local i, repo = 1, nil
	if tokens[1].text == "cd" and tokens[2] and tokens[2].text and tokens[3] and tokens[3].op == "&&" then
		repo = tokens[2].text
		i = 4
	end
	if tokens[i] and tokens[i].text == "rtk" then
		i = i + 1
	end
	local tool = tokens[i]
	if not (tool and tool.text and is_add_tool(tool.text)) then
		return nil
	end
	i = i + 1
	if tokens[i] and tokens[i].text == "-C" and plain(tokens[i + 1]) then
		repo = tokens[i + 1].text
		i = i + 2
	end
	if not (tokens[i] and tokens[i].text == "add" and plain(tokens[i + 1])) then
		return nil
	end
	local request = { title = tokens[i + 1].text, criteria = {}, repo = repo }
	i = i + 2
	while tokens[i] and tokens[i].text do
		local flag, value = tokens[i], tokens[i + 1]
		if not plain(value) then
			return nil
		end
		if flag.text == "--criteria" then
			table.insert(request.criteria, value.text)
		elseif fields[flag.text] then
			request[fields[flag.text]] = value.text
		else
			return nil
		end
		i = i + 2
	end
	if not trailing_ok(tokens, i) then
		return nil
	end
	return request
end

function M.lines(request)
	local out = { "title: " .. request.title }
	if request.description then
		table.insert(out, "description: " .. request.description)
	end
	for _, criterion in ipairs(request.criteria) do
		table.insert(out, "criterion: " .. criterion)
	end
	if request.expeditio then
		table.insert(out, "expeditio: " .. request.expeditio)
	end
	if request.repo then
		table.insert(out, "repo: " .. request.repo)
	end
	return out
end

local wrappers = { env = true, command = true, exec = true, xargs = true, sudo = true, nohup = true, time = true }
local shells = { sh = true, bash = true, zsh = true, dash = true }

local function segments(tokens)
	local out, current, op = {}, {}, nil
	for _, token in ipairs(tokens) do
		if token.op == "&&" or token.op == "|" then
			current.after = op
			table.insert(out, current)
			current, op = {}, token.op
		else
			table.insert(current, token)
		end
	end
	current.after = op
	table.insert(out, current)
	return out
end

local function skip_wrappers(segment)
	local i = 1
	while segment[i] and segment[i].text do
		local text = segment[i].text
		local name = text:match("([^/]+)$")
		if name == "rtk" and segment[i + 1] and segment[i + 1].text == "proxy" then
			i = i + 2
		elseif name == "rtk" or wrappers[name] or text:match("^[%a_][%w_]*=") then
			i = i + 1
		else
			break
		end
	end
	return i
end

local function runs_shell(segment, i)
	local tool = segment[i]
	return tool and tool.text and shells[tool.text:match("([^/]+)$")] ~= nil
end

local function text_of(segment)
	local out = {}
	for _, token in ipairs(segment) do
		if token.text then
			table.insert(out, token.text)
		end
	end
	return table.concat(out, " ")
end

local function adds_in_words(tokens, depth)
	local list = segments(tokens)
	for k, segment in ipairs(list) do
		local i = skip_wrappers(segment)
		local tool = segment[i]
		if tool and tool.text and is_add_tool(tool.text) then
			local nxt = segment[i + 1]
			if nxt and nxt.text == "-C" and plain(segment[i + 2]) then
				nxt = segment[i + 3]
			end
			if nxt and nxt.text == "add" then
				return true
			end
		elseif tool and tool.text and depth < 3 then
			local name = tool.text:match("([^/]+)$")
			local script
			if shells[name] then
				for j = i + 1, #segment do
					if segment[j].text and segment[j].text:match("^%-%a*c$") then
						script = segment[j + 1]
						break
					end
				end
				if not script and segment.after == "|" and k > 1 then
					for before = 1, k - 1 do
						for _, token in ipairs(list[before]) do
							if token.text and M.adds(token.text, depth + 1) then
								return true
							end
						end
						if M.adds(text_of(list[before]), depth + 1) then
							return true
						end
					end
				end
			end
			if name == "eval" then
				script = segment[i + 1]
			end
			if script and script.text and M.adds(script.text, depth + 1) then
				return true
			end
		end
	end
	return false
end

local function unquoted(command)
	local flat = command:gsub("\n", ";")
	local out, i = {}, 1
	while i <= #flat do
		local c = flat:sub(i, i)
		if c == "'" then
			local close = flat:find("'", i + 1, true)
			i = (close or #flat) + 1
		elseif c == '"' then
			i = i + 1
			while i <= #flat and flat:sub(i, i) ~= '"' do
				i = i + (flat:sub(i, i) == "\\" and 2 or 1)
			end
			i = i + 1
		else
			table.insert(out, c)
			i = i + 1
		end
	end
	return table.concat(out)
end

local function looks_like_add(text, quotes)
	local before = quotes and "[%s;&|(/`\"']" or "[%s;&|(/`]"
	local padded = " " .. text
	for _, tool in ipairs({ "todo", "mandatum" }) do
		for pos in padded:gmatch("()" .. before .. tool .. "%s") do
			local rest = padded:sub(pos + #tool + 1):gsub("^%s+", "")
			rest = rest:gsub("^%-C%s+%S+%s+", "")
			if rest:match("^add$") or rest:match("^add%s") then
				return true
			end
		end
	end
	return false
end

local function substitutions(command)
	local out, i = {}, 1
	while i <= #command do
		local c = command:sub(i, i)
		if c == "\\" then
			i = i + 2
		elseif c == "'" then
			local close = command:find("'", i + 1, true)
			i = (close or #command) + 1
		elseif c == "$" and command:sub(i + 1, i + 1) == "(" then
			local depth, j = 1, i + 2
			while j <= #command and depth > 0 do
				local d = command:sub(j, j)
				depth = depth + (d == "(" and 1 or d == ")" and -1 or 0)
				j = j + 1
			end
			table.insert(out, command:sub(i + 2, j - 2))
			i = j
		elseif c == "`" then
			local j = i + 1
			while j <= #command and command:sub(j, j) ~= "`" do
				j = j + (command:sub(j, j) == "\\" and 2 or 1)
			end
			table.insert(out, command:sub(i + 1, j - 1))
			i = j + 1
		else
			i = i + 1
		end
	end
	return out
end

local function without_quoted_heredocs(command)
	local lines, out, ending = {}, {}, nil
	for line in (command .. "\n"):gmatch("(.-)\n") do
		table.insert(lines, line)
	end
	for _, line in ipairs(lines) do
		if ending then
			if line:match("^%s*(.-)%s*$") == ending then
				ending = nil
			end
		else
			table.insert(out, line)
			ending = line:match("<<%-?%s*'([%w_]+)'") or line:match('<<%-?%s*"([%w_]+)"')
		end
	end
	return table.concat(out, "\n")
end

function M.adds(command, depth)
	depth = depth or 0
	if not command or command == "" then
		return false
	end
	command = without_quoted_heredocs(command)
	if depth < 3 then
		for _, inner in ipairs(substitutions(command)) do
			if M.adds(inner, depth + 1) then
				return true
			end
		end
	end
	local tokens = words(command)
	if tokens then
		return adds_in_words(tokens, depth)
	end
	local bare = unquoted(command)
	if looks_like_add(bare) then
		return true
	end
	return (bare:find("sh -c", 1, true) ~= nil or bare:find("eval", 1, true) ~= nil) and looks_like_add(" " .. command, true)
end

return M
