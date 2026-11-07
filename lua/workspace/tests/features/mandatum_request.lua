local mandatum_request = require("workspace.conversations.domain.mandatum_request")
local Question = require("workspace.conversations.domain.question")

return function(t)
	local test, check = t.test, t.check

	local function bash(command, description)
		return Question:new({ id = "q1", tool = "Bash", input = { command = command, description = description } })
	end

	test("a todo add with description, criteria and epic is parsed", function()
		local r = mandatum_request.parse('todo add "t" --description "d" --criteria "a" --criteria "b" --epic "e"')
		check("it parses", r ~= nil, r)
		check("the title is t", r and r.title == "t", r)
		check("the description is d", r and r.description == "d", r)
		check("both criteria are kept in order", r and #r.criteria == 2 and r.criteria[1] == "a" and r.criteria[2] == "b", r and r.criteria)
		check("the epic is the expeditio", r and r.expeditio == "e", r)
	end)

	test("a mandatum add with --expeditio and -C dir is parsed", function()
		local r = mandatum_request.parse('mandatum -C /some/dir add "t" --expeditio "e" --criteria "a"')
		check("it parses past -C", r ~= nil and r.title == "t", r)
		check("--expeditio names the expeditio", r and r.expeditio == "e", r)
		check("the criterion is kept", r and r.criteria[1] == "a", r)
	end)

	test("an rtk or path prefix is skipped", function()
		local r = mandatum_request.parse('rtk todo add "t" --criteria "a"')
		check("rtk is skipped", r ~= nil and r.title == "t", r)
		local home = os.getenv("HOME")
		local p = mandatum_request.parse(home .. '/.config/wezterm/bin/todo add "t" --criteria "a"')
		check("the installed tool under HOME is matched", p ~= nil and p.title == "t", p)
		local env = mandatum_request.parse('$HOME/.config/wezterm/bin/todo add "t" --criteria "a"')
		check("the literal $HOME is an expansion and stays refused", env == nil, env)
	end)

	test("single quotes keep spaces and a double quote inside", function()
		local r = mandatum_request.parse([[todo add 't x' --description 'd "y" z']])
		check("the title keeps its space", r ~= nil and r.title == "t x", r)
		check("the description keeps its quotes", r and r.description == 'd "y" z', r)
	end)

	test("escaped quotes inside double quotes are unescaped", function()
		local r = mandatum_request.parse([[todo add "say \"hi\"" --criteria "a"]])
		check("the title has the quotes", r ~= nil and r.title == 'say "hi"', r)
	end)

	test("other commands and unsafe shapes give nil", function()
		local cases = {
			{ "ls", "ls" },
			{ "ls -la", "ls -la" },
			{ "todo add x && rm y", "chained with &&" },
			{ 'todo add "$HOME"', "$ expansion in double quotes" },
			{ "todo add $HOME", "$ expansion bare" },
			{ 'todo add "t" --bogus "y"', "unknown flag" },
			{ 'todo done 12 "what I did"', "todo done" },
			{ 'todo add "t" | tee out', "pipe" },
			{ 'todo add "unclosed', "unclosed quote" },
		}
		for _, c in ipairs(cases) do
			check("nil for " .. c[2], mandatum_request.parse(c[1]) == nil, mandatum_request.parse(c[1]))
		end
		check("nil for no command", mandatum_request.parse(nil) == nil)
	end)

	test("lines shows the title, description, one line per criterion and the expeditio", function()
		local lines = mandatum_request.lines({ title = "t", description = "d", criteria = { "a", "b" }, expeditio = "e" })
		check("the lines are in order", table.concat(lines, "|") == "title: t|description: d|criterion: a|criterion: b|expeditio: e", lines)
	end)

	test("a Bash todo add shows as a mandatum in the question's details", function()
		local q = bash('todo add "t" --description "d" --criteria "a" --criteria "b" --epic "e"', "ignored")
		local details = q:details()
		check("title, description, a line per criterion, expeditio", table.concat(details, "|") == "title: t|description: d|criterion: a|criterion: b|expeditio: e", details)
	end)

	test("any other Bash command keeps the old $ line and description", function()
		local details = bash("ls -la", "list files"):details()
		check("the command is shown with $ and its description follows", table.concat(details, "|") == "$ ls -la|list files", details)
	end)
	test("a cd, the full path, a repo and 2>&1 give the mandatum with its repo", function()
		local q = bash('cd ~/.config && ~/.config/wezterm/bin/todo add "T" --description "D" --criteria "Given a, when b, then c" --expeditio "E" 2>&1', "ignored")
		check("title, description, criterion, expeditio and repo", table.concat(q:details(), "|") == "title: T|description: D|criterion: Given a, when b, then c|expeditio: E|repo: ~/.config", q:details())
	end)

	test("the same command with a trailing | head -20 gives the same lines", function()
		local q = bash('cd ~/.config && ~/.config/wezterm/bin/todo add "T" --description "D" --criteria "Given a, when b, then c" --expeditio "E" 2>&1 | head -20', "ignored")
		check("the filter doesn't change the lines", table.concat(q:details(), "|") == "title: T|description: D|criterion: Given a, when b, then c|expeditio: E|repo: ~/.config", q:details())
	end)

	test("a tool that isn't the installed one, a glob, a tilde in a title, a backslash-newline, a pipe to sh and a stray cd give nil", function()
		local cases = {
			{ "./todo add x", "./todo" },
			{ "/tmp/x/todo add x", "/tmp/x/todo" },
			{ "todo add *", "unquoted glob" },
			{ "todo add ~/x", "a word that starts with ~" },
			{ "todo add x --description ~root", "a flag value that starts with ~" },
			{ 'todo add "t" \\' .. "\n" .. '--criteria "a"', "backslash-newline" },
			{ "todo add x | sh", "pipe to sh" },
			{ "cd a && rm b && todo add x", "stray cd chain" },
		}
		for _, c in ipairs(cases) do
			check("nil for " .. c[2], mandatum_request.parse(c[1]) == nil, mandatum_request.parse(c[1]))
		end
	end)
	test("a tool path that is not the installed one gives nil", function()
		local cases = {
			{ "/tmp/evil/.config/wezterm/bin/todo add x", "a copy under another root" },
			{ "/Users/someoneelse/.config/wezterm/bin/todo add x", "the same path under another home" },
			{ "todo add x|| head -5", "|| before head" },
			{ "todo add x||", "|| after the title" },
		}
		for _, c in ipairs(cases) do
			check("nil for " .. c[2], mandatum_request.parse(c[1]) == nil, mandatum_request.parse(c[1]))
		end
	end)
	test("a ~ inside a word stays literal, as the shell leaves it", function()
		local r = mandatum_request.parse('todo add a~b --criteria "a"')
		check("the title is a~b", r ~= nil and r.title == "a~b", r)
	end)
end
