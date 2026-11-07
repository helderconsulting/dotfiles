local app = require("workspace.workbench.presentation.nvim.app")
local drafts = require("workspace.conversations.presentation.nvim.drafts")
local session_files = require("workspace.shared.providers").current().session_files
local view_mapper = require("workspace.legio.presentation.mappers.miles_view_mapper")
local legio_view_mapper = require("workspace.legio.presentation.mappers.legio_view_mapper")
local ConversationScreen = require("workspace.conversations.presentation.conversation_screen")

local M = {}

M.name = "session"

local cache = {}

local function roster()
	return app.services().roster
end

local function runner()
	return app.services().miles_runner
end

local function parse(text, mtime)
	local info = { mtime = mtime }
	local custom, ai
	for line in (text or ""):gmatch("[^\n]+") do
		if not info.cwd and line:sub(1, 7) == '"cwd":"' then
			info.cwd = line:match('^"cwd":"(.*)"$')
		elseif line:sub(1, 1) == "{" then
			local ok, entry = pcall(vim.json.decode, line)
			if ok and type(entry) == "table" then
				custom = entry.customTitle or custom
				ai = entry.aiTitle or ai
			end
		end
	end
	info.title = custom or ai
	return info
end

local function recent(folder, limit, done)
	local files = {}
	for _, path in ipairs(vim.fn.glob(app.paths.provider.projects .. "/" .. folder:gsub("[^%w]", "-") .. "*/*.jsonl", false, true)) do
		local st = vim.uv.fs_stat(path)
		if st then
			table.insert(files, { path = path, mtime = st.mtime.sec, id = vim.fn.fnamemodify(path, ":t:r") })
		end
	end
	table.sort(files, function(a, b)
		return a.mtime > b.mtime
	end)
	files = vim.list_slice(files, 1, limit)
	local stale = vim.tbl_filter(function(f)
		return not cache[f.path] or cache[f.path].mtime ~= f.mtime
	end, files)
	if #stale == 0 then
		return done(files)
	end
	local left = #stale
	for _, f in ipairs(stale) do
		vim.system({ "/usr/bin/grep", "-o", "-E", '"cwd":"[^"]*"|^\\{"type":"(custom-title|ai-title)".*', f.path }, { text = true, env = { LC_ALL = "C" } }, function(res)
			vim.schedule(function()
				cache[f.path] = parse(res.stdout, f.mtime)
				left = left - 1
				if left == 0 then
					done(files)
				end
			end)
		end)
	end
end

local function deployed_hidden()
	local service = app.services().legio_process
	return legio_view_mapper.deployed_miles_ids(service and service:legiones() or {})
end

local function active_rows(folder, draft, contubernia)
	local key = drafts.starts_session(draft) and drafts.key(draft) or nil
	return view_mapper.to_active_rows(roster():running_in(folder), folder, draft, key, contubernia, deployed_hidden())
end

function M.card_lines(row)
	if not (row.miles_id and row.root) then
		return view_mapper.to_card_lines(row)
	end
	local counts = require("workspace.workflow.presentation.nvim.review_marks").counts(row.root)
	local merge_requests = app.services().merge_request_process
	local merge_request = merge_requests.allows(row.role) and merge_requests:summary(row.root) or nil
	return view_mapper.to_card_lines(row, counts, merge_request and merge_request.card_lines)
end

function M.card_on_render(e)
	return M.card_lines(e)
end

local function sessions(folder, limit, done)
	recent(folder, limit, function(files)
		done(view_mapper.to_session_list(active_rows(folder), files, cache, folder, app.now()))
	end)
end

function M.entries_on_refresh(folder, done)
	local view = app.screen(ConversationScreen)
	local list = active_rows(folder, view.state == "draft" and view.draft or nil, roster():all_contubernia())
	for _, e in ipairs(list) do
		e.component = M
	end
	done(list)
end

function M.dto(miles_id)
	local service = roster()
	return service and miles_id and service:get(miles_id) or nil
end

function M.live_row(miles_id, label, position)
	local dto = M.dto(miles_id)
	if not dto then
		return nil
	end
	local row = view_mapper.to_miles_row(dto, nil, label, position)
	row.component = M
	return row
end

function M.entry_for(miles_id, name)
	return M.live_row(miles_id) or { id = miles_id, miles_id = miles_id, name = name, target = { agent = miles_id, name = name }, cannot_end = name .. " isn't running", needs_resume = false, component = M }
end

function M.thread_on_select(e, ctx)
	return app.services().conversation_thread:for_session(e.id, e.miles_id, e.cwd, ctx.log, drafts.load({ agent = e.id }))
end

function M.show_conversation_on_select(e, item, opts)
	if e.drafting then
		return
	end
	local miles = { id = e.id, cwd = e.cwd, name = e.name }
	local incoming = opts and opts.incoming
	return app.update_screen(ConversationScreen, function(v)
		return v:follow_item(miles, item, incoming)
	end)
end

local function edit_in_flight(item, e)
	runner():interrupt(e.miles_id)
	drafts.write({ agent = e.id }, item.text or app.services().conversation_thread:last_prompt(e.id) or "")
	drafts.compose({ agent = e.id, cwd = e.cwd, name = e.name })
end

function M.handled_on_escape(e, item)
	if not (item and e.miles_id) then
		return false
	elseif item.outbox then
		runner():send_now(view_mapper.to_send_now_command(e.miles_id, item.outbox))
		return true
	elseif item.working or item.pending then
		edit_in_flight(item, e)
		return true
	end
	return false
end

local function warn(ui, why)
	if why and not ui.batch then
		vim.notify(why, vim.log.levels.WARN)
	end
end

function M.open_on_enter(e)
	if e.drafting then
		return drafts.compose(e.target)
	end
	app.update_screen(ConversationScreen, function(v)
		v:select(e.id)
	end)
	if e.needs_resume then
		runner():resume(view_mapper.to_resume_command(e))
	end
end

local function finish(e, ui)
	if e.cannot_end then
		return warn(ui, e.cannot_end)
	end
	if ui.confirm("end session " .. e.name .. "? it stays resumable") then
		runner():stop(e.miles_id, nil, "ended_by_commander")
	end
end

local function toggle(e, ui)
	if e.toggle == "resume" then
		return M.open_on_enter(e)
	end
	finish(e, ui)
end

local function fresh_row(e)
	local dto = roster():get(e.id)
	return dto and view_mapper.to_miles_row(dto, e.name) or e
end

local function interrupt(e, ui)
	local why = fresh_row(e).cannot_interrupt
	if why then
		return warn(ui, why)
	end
	runner():interrupt(e.id)
	if not ui.batch then
		vim.notify("interrupted " .. e.name)
	end
end

local function message(e)
	drafts.compose(e.target)
end

local function continue_after_limit(e, ui)
	local why = fresh_row(e).cannot_continue
	if why then
		return warn(ui, why)
	end
	runner():continue(e.id, function(sent)
		if sent and not ui.batch then
			vim.notify(e.name .. " continues")
		end
	end)
end

local function new_session(p, picker)
	runner():catalog(p.cwd, function(catalog)
		local mandata = require("workspace.workflow.presentation.nvim.mandatum_actions")
		local next_step = p.mandata and ("it starts on " .. mandata.titles(p.mandata)) or "write the task"
		picker.pick(picker.flatten(catalog), { prompt = "new session", header = "Enter picks the model, then the mode" }, function(choice)
			picker.pick(picker.modes(roster():permission_modes(), roster():default_mode()), { prompt = "mode", header = "Enter picks it, then " .. next_step }, function(mode)
				local launch = { provider = choice.provider, model = choice.value, mode = mode.value }
				if p.mandata then
					return mandata.start_new(p.mandata, p.cwd, launch)
				end
				drafts.compose(vim.tbl_extend("force", { cwd = p.cwd, name = p.name }, launch))
			end)
		end)
	end)
end

local function running(p)
	if roster():get(p.miles) then
		return true
	end
	vim.notify(p.name .. " isn't running", vim.log.levels.WARN)
	return false
end

local function pick_model(p, picker)
	if not running(p) then
		return
	end
	runner():models(p.miles, function(catalog)
		picker.pick(picker.flatten(catalog, runner():setup(p.miles)), { prompt = "model for " .. p.name, header = "Enter switches to it" }, function(choice)
			runner():set_model(view_mapper.to_set_model_command(p.miles, choice.value), function(ok)
				if ok then
					vim.notify(p.name .. " now uses " .. choice.value)
				end
			end)
		end)
	end)
end

local function pick_mode(p, picker)
	if not running(p) then
		return
	end
	picker.pick(picker.modes(roster():permission_modes(), runner():setup(p.miles).mode), { prompt = "mode for " .. p.name, header = "Enter switches to it" }, function(choice)
		runner():set_mode(view_mapper.to_set_mode_command(p.miles, choice.value), function(ok)
			if ok then
				vim.notify(p.name .. " is now in " .. choice.value .. " mode")
			end
		end)
	end)
end

local pickers = {
	new_session = new_session,
	model = pick_model,
	send_mandata = function(p, picker)
		require("workspace.workflow.presentation.nvim.mandatum_actions").send_picker(p, picker)
	end,
	mode = pick_mode,
}

function M.pick(p)
	local open = p and pickers[p.kind]
	if open then
		open(p, require("workspace.legio.presentation.nvim.model_picker"))
	end
end

local function request_pick(pick)
	app.update_screen(ConversationScreen, function(v)
		v:request_pick(pick, app.now())
	end)
	app.focus("conversation")
end

local function move_to_sdk(e, ui)
	if e.cannot_move then
		return warn(ui, e.cannot_move)
	end
	runner():move_to_sdk(e.id, function(moved, reason)
		vim.notify(moved and (e.name .. " moved to the sdk") or ("couldn't move " .. e.name .. ": " .. tostring(reason)), moved and vim.log.levels.INFO or vim.log.levels.WARN)
	end)
end

local function switch_mode(e, ui)
	if not (e.miles_id and e.on_sdk) then
		return warn(ui, e.name .. " isn't on the sdk, its mode can't change from here")
	end
	request_pick({ kind = "mode", miles = e.id, name = e.name })
end

local function switch_model(e, ui)
	if not (e.miles_id and roster():get(e.id)) then
		return warn(ui, e.name .. " isn't running")
	end
	request_pick({ kind = "model", miles = e.id, name = e.name })
end

local function rename(e, ui)
	vim.ui.input({ prompt = "rename session: ", default = e.name }, function(name)
		local title, why = view_mapper.to_new_title(e, name)
		if not title then
			return warn(ui, why)
		end
		session_files.rename(e.path, e.id, title)
		ui.refresh()
	end)
end

local function open_merge_request(e)
	local merge_requests = app.services().merge_request_process
	if not merge_requests.allows(e.role) then
		return vim.notify("only the decanus has one", vim.log.levels.WARN)
	end
	local url = merge_requests:url_of(e.root or e.cwd)
	if not url then
		return vim.notify("no merge request for " .. vim.fs.basename(e.root or e.cwd or "this folder"), vim.log.levels.INFO)
	end
	vim.ui.open(url)
end

local function remove(e, ui)
	local plan, why = view_mapper.to_removal_plan(e, vim.fn.glob(app.paths.provider.projects .. "/*/" .. e.id .. ".jsonl"))
	if not plan then
		return warn(ui, why)
	end
	if not ui.confirm((plan.stop_first and "stop and delete session " or "delete session ") .. e.name .. "?") then
		return
	end
	local function delete()
		vim.fs.rm(plan.path, { force = true })
		if vim.fn.isdirectory(plan.sidecar) == 1 then
			vim.fs.rm(plan.sidecar, { recursive = true, force = true })
		end
		cache[plan.path] = nil
		ui.refresh()
	end
	if plan.stop_first then
		runner():stop(e.miles_id, function()
			vim.defer_fn(delete, 500)
		end, "ended_by_commander")
	else
		delete()
	end
end

local search_limit = 200
local tone_colors = { busy = "#A58BD3", ok = "#77DD77", bad = "#E0955A", off = "#8C8C8C", limit = "#E06C75" }

local search_actions = {
	{ key = "enter", label = "go there or resume", run = M.open_on_enter },
	{ key = "ctrl-x", label = "end", run = finish },
	{ key = "ctrl-t", label = "interrupt", run = interrupt },
	{ key = "ctrl-o", label = "message", run = message },
	{ key = "ctrl-r", label = "rename", run = rename },
	{ key = "ctrl-d", label = "delete", run = remove },
}

local search_ui = {
	confirm = function(question)
		return vim.fn.confirm(question, "&yes\n&no", 2) == 1
	end,
	refresh = function() end,
}

function M.find()
	local folder = app.folder()
	sessions(folder, search_limit, function(list)
		if #list == 0 then
			return vim.notify("no sessions in " .. app.short(folder), vim.log.levels.WARN)
		end
		require("packs.fzf")
		local fzf = require("fzf-lua")
		local utils = require("fzf-lua.utils")
		local width = 4
		for _, e in ipairs(list) do
			width = math.max(width, vim.fn.strdisplaywidth(e.name))
		end
		local lines, by_line = {}, {}
		for _, e in ipairs(list) do
			local word, name, detail = e.search_word, e.name, e.search_detail
			local line = ("%s  %s  %s"):format(
				utils.ansi_from_rgb(tone_colors[e.kind] or tone_colors.off, ("%-8s"):format(word)),
				name .. string.rep(" ", width - vim.fn.strdisplaywidth(name)),
				utils.ansi_from_rgb("#3F6F3F", detail)
			)
			table.insert(lines, line)
			by_line[vim.trim(utils.strip_ansi_coloring(line))] = e
		end
		local legend, actions = { {}, {} }, {}
		for i, a in ipairs(search_actions) do
			table.insert(legend[i <= 3 and 1 or 2], utils.ansi_from_rgb("#77DD77", a.key) .. " " .. a.label)
			actions[a.key] = function(selected)
				local e = selected and selected[1] and by_line[vim.trim(utils.strip_ansi_coloring(selected[1]))]
				if e then
					a.run(e, search_ui)
				end
			end
		end
		fzf.fzf_exec(lines, {
			prompt = "sessions> ",
			fzf_opts = { ["--ansi"] = true, ["--no-sort"] = true, ["--header"] = table.concat(legend[1], "  ·  ") .. "\n" .. table.concat(legend[2], "  ·  ") },
			actions = actions,
		})
	end)
end

M.groups = {
	{ "<leader>s", "miles" },
}

M.actions = {
	{
		"<leader>sa",
		function(e, ui, item)
			local mandatum = item and item.mandatum
			local folder = mandatum and e.root or ui.folder()
			request_pick({ kind = "new_session", cwd = folder, name = app.short(folder), mandata = mandatum and { mandatum.id } or nil })
		end,
		"new miles",
		always = true,
	},
	{
		"<leader>sf",
		function()
			app.update_screen(ConversationScreen, function(v)
				v:request_search(app.now())
			end)
			app.focus("conversation")
		end,
		"find a miles",
		always = true,
	},
	{ "<leader>ss", toggle, "resume or end a miles" },
	{ "<leader>sm", message, "message a miles", single = true },
	{ "<leader>si", interrupt, "interrupt a miles" },
	{ "<leader>sc", continue_after_limit, "continue a miles after a usage limit" },
	{ "<leader>sr", rename, "rename a miles", single = true },
	{ "<leader>su", move_to_sdk, "move a miles to the sdk" },
	{ "<leader>sd", remove, "delete a miles" },
	{ "<leader>so", open_merge_request, "open a merge request for a miles", single = true },
	{ "<leader>sM", switch_model, "miles model", single = true },
	{ "<leader>sp", switch_mode, "miles permission mode", single = true },
}

local function update_milites_from_session_files()
	return app.services().miles_session_events:sync_session_files()
end

function M.watch_session_files()
	local debounce, again = vim.uv.new_timer(), vim.uv.new_timer()
	local function run()
		local wait = update_milites_from_session_files()
		again:stop()
		if wait then
			again:start(math.ceil(wait * 1000) + 50, 0, vim.schedule_wrap(run))
		end
	end
	local watcher = vim.uv.new_fs_event()
	vim.fn.mkdir(app.paths.provider.sessions, "p")
	watcher:start(app.paths.provider.sessions, {}, function()
		debounce:start(50, 0, vim.schedule_wrap(run))
	end)
	vim.api.nvim_create_autocmd("FocusGained", { callback = run })
	run()
end

return M
