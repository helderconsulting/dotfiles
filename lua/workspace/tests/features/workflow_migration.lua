local MIGRATION = "workspace.workflow.infrastructure.outbound.filesystem.expeditio_migration"

local function write_record(root, folder, id, record)
	vim.fn.mkdir(root .. "/" .. folder, "p")
	vim.fn.writefile({ vim.json.encode(record) }, root .. "/" .. folder .. "/" .. id .. ".json")
end

local function read_json(path)
	return vim.json.decode(table.concat(vim.fn.readfile(path), "\n"))
end

local function records(root, folder)
	local out = {}
	for _, path in ipairs(vim.fn.glob(root .. "/" .. folder .. "/*.json", false, true)) do
		out[vim.fn.fnamemodify(path, ":t:r")] = read_json(path)
	end
	return out
end

local function legacy_fixture(root)
	write_record(root, "epics", "e176c", { id = "e176c", title = "hexagonal restructure", root = "/repo", from = "s1", created = 1793969161.5 })
	write_record(root, "epics", "e2b00", { id = "e2b00", title = "sidebar", root = "/repo", from = "you", created = 1793969200.25 })
	write_record(root, "todos", "t1a2b3", { id = "t1a2b3", text = "# Move workflow\n\nbody", root = "/repo", from = "you", created = 1793969300.5, state = "open", epic = "e176c" })
	write_record(root, "todos", "t4c5d6", {
		id = "t4c5d6",
		text = "# Rename\n",
		root = "/repo",
		from = "you",
		created = 1793969400,
		state = "done",
		epic = "e176c",
		assignee = "a1",
		assigned_at = 1793969500,
		done_at = 1793969600,
		note = "shipped",
	})
end

local function run_migration(store)
	local ok, mod = pcall(require, MIGRATION)
	if not ok then
		return false, "no migration module " .. MIGRATION .. ": " .. tostring(mod)
	end
	return pcall(mod.run, store)
end

local function same_fields(old, new, renamed)
	for key, value in pairs(old) do
		local target = renamed[key] or key
		if not vim.deep_equal(new[target], value) then
			return false, key
		end
	end
	return true
end

local function snapshot(root)
	return vim.inspect({ expeditiones = records(root, "expeditiones"), mandata = records(root, "mandata") })
end

local function write_text(path, text)
	vim.fn.mkdir(vim.fs.dirname(path), "p")
	vim.fn.writefile({ text }, path)
end

local function read_text(path)
	return table.concat(vim.fn.readfile(path), "\n")
end

local function folder_text(dir)
	local out = {}
	for _, path in ipairs(vim.fn.glob(dir .. "/*", false, true)) do
		out[vim.fn.fnamemodify(path, ":t")] = read_text(path)
	end
	return vim.inspect(out)
end

local function legacy_screens(root)
	write_record(root, "conversation_screens", "s1", {
		id = "s1",
		entry = { kind = "epic", id = "e176c" },
		draft = { epic = "e176c", in_epic = true, text = "keep this" },
	})
	write_record(root, "conversation_screens", "s2", {
		id = "s2",
		entry = { kind = "todo", id = "t1a2b3" },
		draft = { todo = "t1a2b3", in_epic = false },
	})
	write_record(root, "conversation_screens", "s3", { id = "s3", entry = { kind = "miles", id = "a1" } })
end

local function legacy_drafts(root)
	write_text(root .. "/drafts/epic-e176c.md", "epic draft")
	write_text(root .. "/drafts/todo-t1a2b3.md", "todo draft")
	write_text(root .. "/drafts/other.md", "other draft")
end

return function(t)
	local test, check, make_store = t.test, t.check, t.make_store

	test("epics are copied to expeditiones and todos to mandata", function()
		local root = vim.fn.tempname() .. "/workspace"
		legacy_fixture(root)
		local ok, err = run_migration(make_store(vim.fs.dirname(root)))
		check("the migration runs", ok, err)
		local expeditiones, mandata = records(root, "expeditiones"), records(root, "mandata")
		check("both epics are in expeditiones", #vim.tbl_keys(expeditiones) == 2 and expeditiones.e176c ~= nil and expeditiones.e2b00 ~= nil, vim.tbl_keys(expeditiones))
		check("both todos are in mandata", #vim.tbl_keys(mandata) == 2 and mandata.t1a2b3 ~= nil and mandata.t4c5d6 ~= nil, vim.tbl_keys(mandata))
		vim.fn.delete(root, "rf")
	end)

	test("nothing is lost in the migration", function()
		local root = vim.fn.tempname() .. "/workspace"
		legacy_fixture(root)
		local ok, err = run_migration(make_store(vim.fs.dirname(root)))
		if not ok then
			check("the migration runs", false, err)
			vim.fn.delete(root, "rf")
			return
		end
		local expeditiones, mandata = records(root, "expeditiones"), records(root, "mandata")
		for _, id in ipairs({ "e176c", "e2b00" }) do
			local old = read_json(root .. "/epics/" .. id .. ".json")
			local same, key = same_fields(old, expeditiones[id] or {}, {})
			check("expeditio " .. id .. " keeps every field", same and expeditiones[id] ~= nil, key or id)
		end
		for _, id in ipairs({ "t1a2b3", "t4c5d6" }) do
			local old = read_json(root .. "/todos/" .. id .. ".json")
			local same, key = same_fields(old, mandata[id] or {}, { epic = "expeditio" })
			check("mandatum " .. id .. " keeps every field", same and mandata[id] ~= nil, key or id)
		end
		check("the legacy epic and todo files are not changed", read_json(root .. "/epics/e176c.json").title == "hexagonal restructure" and read_json(root .. "/todos/t4c5d6.json").note == "shipped")
		vim.fn.delete(root, "rf")
	end)

	test("running the migration again changes nothing", function()
		local root = vim.fn.tempname() .. "/workspace"
		legacy_fixture(root)
		run_migration(make_store(vim.fs.dirname(root)))
		local before = snapshot(root)
		local ok, err = run_migration(make_store(vim.fs.dirname(root)))
		check("the second run succeeds", ok, err)
		check("the second run leaves expeditiones and mandata unchanged", snapshot(root) == before)
		vim.fn.delete(root, "rf")
	end)

	test("conversation screens move to expeditio and mandatum entries", function()
		local root = vim.fn.tempname() .. "/workspace"
		legacy_screens(root)
		local ok, err = run_migration(make_store(vim.fs.dirname(root)))
		check("the migration runs", ok, err)
		local screens = records(root, "conversation_screens")
		local s1, s2, s3 = screens.s1 or {}, screens.s2 or {}, screens.s3 or {}
		check("an epic entry becomes an expeditio entry and keeps its id", s1.entry and s1.entry.kind == "expeditio" and s1.entry.id == "e176c", s1.entry)
		check("an epic draft becomes an expeditio draft", s1.draft and s1.draft.expeditio == "e176c" and s1.draft.epic == nil, s1.draft)
		check("in_epic becomes in_expeditio and keeps its value", s1.draft and s1.draft.in_expeditio == true and s1.draft.in_epic == nil and s1.draft.text == "keep this", s1.draft)
		check("a todo entry becomes a mandatum entry and keeps its id", s2.entry and s2.entry.kind == "mandatum" and s2.entry.id == "t1a2b3", s2.entry)
		check("a todo draft becomes a mandatum draft", s2.draft and s2.draft.mandatum == "t1a2b3" and s2.draft.todo == nil, s2.draft)
		check("in_expeditio keeps false", s2.draft and s2.draft.in_expeditio == false and s2.draft.in_epic == nil, s2.draft)
		check("a screen for another kind is left alone", vim.deep_equal(s3, { id = "s3", entry = { kind = "miles", id = "a1" } }), s3)
		local before = folder_text(root .. "/conversation_screens")
		run_migration(make_store(vim.fs.dirname(root)))
		check("a second run changes no screen", folder_text(root .. "/conversation_screens") == before)
		vim.fn.delete(root, "rf")
	end)

	test("epic and todo drafts are copied to expeditio and mandatum drafts", function()
		local root = vim.fn.tempname() .. "/workspace"
		legacy_drafts(root)
		local ok, err = run_migration(make_store(vim.fs.dirname(root)))
		check("the migration runs", ok, err)
		check("an epic draft is copied to an expeditio draft", vim.fn.filereadable(root .. "/drafts/expeditio-e176c.md") == 1 and read_text(root .. "/drafts/expeditio-e176c.md") == "epic draft")
		check("a todo draft is copied to a mandatum draft", vim.fn.filereadable(root .. "/drafts/mandatum-t1a2b3.md") == 1 and read_text(root .. "/drafts/mandatum-t1a2b3.md") == "todo draft")
		check("the original epic and todo drafts are kept", read_text(root .. "/drafts/epic-e176c.md") == "epic draft" and read_text(root .. "/drafts/todo-t1a2b3.md") == "todo draft")
		check("other drafts are not copied", vim.fn.filereadable(root .. "/drafts/mandatum-other.md") == 0 and vim.fn.filereadable(root .. "/drafts/expeditio-other.md") == 0)
		local before = folder_text(root .. "/drafts")
		run_migration(make_store(vim.fs.dirname(root)))
		check("a second run adds no draft", folder_text(root .. "/drafts") == before)
		vim.fn.delete(root, "rf")
	end)
end
