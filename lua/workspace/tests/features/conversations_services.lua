local Question = require("workspace.conversations.domain.question")

local app_module = "workspace.workbench.presentation.nvim.app"
local view_modules = { "workspace.conversations.presentation.nvim.question_view", "workspace.conversations.presentation.nvim.answer_view" }

local function presentation_files()
	local workspace_dir = vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0])))
	return vim.fn.glob(workspace_dir .. "/conversations/presentation/**/*.lua", false, true)
end

local function requires_of(path)
	local out = {}
	for line in io.lines(path) do
		local mod = line:match('require%(%s*"([^"]+)"%s*%)')
		if mod then
			table.insert(out, mod)
		end
	end
	return out
end

local function forbidden(mod)
	if mod:find("^workspace%.conversations%.") and not (mod:find("^workspace%.conversations%.application%.") or mod:find("^workspace%.conversations%.presentation%.")) then
		return true
	end
	return mod:find("%.domain%.") ~= nil or mod:find("%.infrastructure%.") ~= nil or mod:find("^workspace%.shared%.state%.") ~= nil
end

local function contains(value, needle, seen)
	if value == needle then
		return true
	end
	if type(value) ~= "table" then
		return false
	end
	seen = seen or {}
	if seen[value] then
		return false
	end
	seen[value] = true
	for k, v in pairs(value) do
		if contains(k, needle, seen) or contains(v, needle, seen) then
			return true
		end
	end
	return false
end

local function with_modules(mods, fn)
	local saved = {}
	for name, mod in pairs(mods) do
		saved[name] = package.loaded[name]
		package.loaded[name] = mod
	end
	for _, name in ipairs(view_modules) do
		saved[name] = saved[name] or package.loaded[name]
		package.loaded[name] = nil
	end
	local ok, err = pcall(fn)
	for name, mod in pairs(saved) do
		package.loaded[name] = mod
	end
	if not ok then
		error(err, 0)
	end
end

local function keymap_callback(buf, lhs)
	for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf, "n")) do
		if map.lhs == lhs then
			return map.callback
		end
	end
end

return function(t)
	local test, check = t.test, t.check

	test("conversations presentation requires only application services", function()
		local offending = {}
		for _, path in ipairs(presentation_files()) do
			for _, mod in ipairs(requires_of(path)) do
				if forbidden(mod) then
					table.insert(offending, vim.fn.fnamemodify(path, ":t") .. " requires " .. mod)
				end
			end
		end
		check("no presentation file requires a domain, infrastructure or store module", #offending == 0, offending)
	end)

	test("answering a question in the conversation pane goes through the inquiry service", function()
		local store = t.make_store(vim.fn.tempname())
		local services = require("workspace.composition_root").build(store, { clock = os.time })
		local inquiry = services.inquiry
		local calls = {}
		check("the conversations feature exposes an inquiry service", inquiry ~= nil)
		if inquiry and type(inquiry.answer) == "function" then
			local answer = inquiry.answer
			inquiry.answer = function(self, ...)
				table.insert(calls, { ... })
				return answer(self, ...)
			end
		else
			check("the inquiry service has an answer method", false)
		end

		local ask = Question.from_sdk({
			session = "s1",
			tool = "AskUserQuestion",
			input = { questions = { { question = "Which?", header = "Pick", options = { { label = "A" }, { label = "B" } } } } },
			cwd = "/code/app",
		}, "q1", os.time())
		store:put(Question, ask)

		local fake_app = {
			role = "conversation",
			store = function()
				return store
			end,
			services = function()
				return services
			end,
			now = function()
				return os.time()
			end,
		}

		with_modules({ [app_module] = fake_app }, function()
			local question_view = require("workspace.conversations.presentation.nvim.question_view")
			local buf = question_view.buffer("q1", nil)
			check("a pending question is shown in the pane", buf ~= nil)
			local pick = buf and keymap_callback(buf, "1")
			check("the first option can be picked", pick ~= nil)
			if pick then
				pick()
			end
		end)

		check("the answer reaches the inquiry service once", #calls == 1, #calls)
		check("the inquiry service receives the question id", calls[1] ~= nil and contains(calls[1], "q1"))
		check("the inquiry service receives the chosen answer", calls[1] ~= nil and contains(calls[1], "A"))
		local stored = store:get(Question, "q1")
		check("the question is answered", stored ~= nil and stored.state == "answered" and stored.answers ~= nil and stored.answers["Which?"] == "A")
	end)
end
