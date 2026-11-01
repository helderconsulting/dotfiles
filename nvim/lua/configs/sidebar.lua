-- The sidebar: a Neovim in a narrow pane on the left of a workspace tab (wezterm/agents.lua runs
-- nvim +Sidebar), listing the workspaces (configs/workspaces.lua) or the agents (configs/agents.lua)
-- as cards (configs/cards.lua), like a mailbox. The two sections are tabs in the pane's WezTerm bar entry, like the
-- docker view's entries: the sidebar user var carries them with their counts, which also tells
-- WezTerm this pane is the sidebar, not the workspace's editor. ALT left and right go through them,
-- and past the ends on to the next pane like the rest of the ALT arrow grid (configs/keymaps.lua).
-- j and k (or the arrows) move a card at a time, with a count like 5j, gg and G go to the first and
-- last card and 12G to the twelfth. Enter goes there (a running workspace or agent) or opens it (a
-- closed project, an earlier session), and each section's other actions sit under the leader, as
-- in the docker view, where which-key shows only the current section's.
local workspaces = require("configs.workspaces")
local agents = require("configs.agents")
local cards = require("configs.cards")

local M = {}

-- A card's three lines per section. The pane is narrow, so a folder shows its own name first and
-- where it sits below (ceuz/automator-1.0 and -2.0 would cut to the same text).
local function parent(dir)
	return dir and workspaces.short(vim.fs.dirname(dir)) or ""
end
local sections = {
	{
		name = "workspaces",
		list = workspaces,
		card = function(e)
			return { vim.fs.basename(e.dir), parent(e.dir), e.word .. (e.here and " · here" or "") }
		end,
	},
	{
		name = "agents",
		list = agents,
		card = function(e)
			return { e.name, e.cwd and vim.fs.basename(e.cwd) or e.host, e.word }
		end,
	},
}
local state = { section = 1, entries = {}, current = {} }
local buf, win
local ns = vim.api.nvim_create_namespace("sidebar")

local function section()
	return sections[state.section]
end

local function entries()
	return state.entries[section().name] or {}
end

local function current_index()
	for i, e in ipairs(entries()) do
		if e.id == state.current[section().name] then
			return i
		end
	end
	return entries()[1] and 1 or nil
end

local function current_entry()
	local i = current_index()
	return i and entries()[i]
end

-- Tell WezTerm (wezterm/agents.lua) the sections as tabs with their counts, the current one marked,
-- for the bar entry; only when that changed, and empty when Neovim leaves.
local last_report
local function report(value)
	if vim.env.WEZTERM_PANE and value ~= last_report then
		last_report = value
		vim.api.nvim_ui_send(("\27]1337;SetUserVar=sidebar=%s\7"):format(vim.base64.encode(value)))
	end
end

local function report_tabs()
	local tabs = {}
	for i, s in ipairs(sections) do
		table.insert(tabs, { name = s.name, count = #(state.entries[s.name] or {}), current = i == state.section })
	end
	report(vim.json.encode({ tabs = tabs }))
end

local function render()
	report_tabs()
	state.moving = true
	cards.render(buf, win, ns, entries(), section().card, current_index())
	state.moving = false
end

-- Natural order like the docker view: the entries a section puts first, then by name with numbers
-- compared as numbers.
local function natural(name)
	return (name or ""):lower():gsub("%d+", function(n)
		return ("%012d"):format(tonumber(n))
	end)
end

local function refresh()
	for _, s in ipairs(sections) do
		s.list.fetch(function(list)
			table.sort(list, function(a, b)
				if (a.order or 1) ~= (b.order or 1) then
					return (a.order or 1) < (b.order or 1)
				end
				return natural(a.name) < natural(b.name)
			end)
			state.entries[s.name] = list
			render()
		end, { folder = state.folder })
	end
end

-- Moving ---------------------------------------------------------------------------------------

local function select(index)
	local list = entries()
	if #list == 0 then
		return
	end
	index = math.max(1, math.min(#list, index))
	state.current[section().name] = list[index].id
	render()
end

local function step(delta)
	select((current_index() or 1) + delta * vim.v.count1)
end

local function go(first)
	select(vim.v.count > 0 and vim.v.count or first and 1 or #entries())
end

local set_actions

-- Past the ends hand the move to WezTerm, like the docker view; the clock makes every request a
-- change for WezTerm's user-var-changed event.
local function hand_off(direction)
	if vim.env.WEZTERM_PANE then
		local value = vim.base64.encode(direction .. ":" .. vim.uv.hrtime())
		vim.api.nvim_ui_send(("\27]1337;SetUserVar=nav=%s\7"):format(value))
	end
end

local function switch(delta, direction)
	if not sections[state.section + delta] then
		return hand_off(direction)
	end
	state.section = state.section + delta
	set_actions()
	render()
end

-- Actions --------------------------------------------------------------------------------------

-- What the sections' actions get besides their entry, like the docker view's.
local view = {}

function view.run(cmd, opts)
	opts = opts or {}
	vim.system(cmd, { text = true, env = opts.env }, function(res)
		vim.schedule(function()
			if opts.done then
				opts.done(res)
			end
			if res.code ~= 0 then
				vim.notify(vim.trim(res.stderr ~= "" and res.stderr or res.stdout), vim.log.levels.ERROR)
			end
			refresh()
		end)
	end)
end

function view.refresh()
	refresh()
end

function view.confirm(question)
	return vim.fn.confirm(question, "&yes\n&no", 2) == 1
end

local mapped = {}

function set_actions()
	for _, lhs in ipairs(mapped) do
		pcall(vim.keymap.del, "n", lhs, { buffer = buf })
	end
	mapped = {}
	for _, a in ipairs(section().list.actions or {}) do
		table.insert(mapped, a[1])
		vim.keymap.set("n", a[1], function()
			local e = current_entry()
			if e or a.always then
				a[2](e, view)
			end
		end, { buffer = buf, desc = a[3], nowait = true })
	end
	-- which-key reads a buffer's mappings once; have it read them again.
	local ok, wk_buf = pcall(require, "which-key.buf")
	if ok and wk_buf.clear then
		pcall(wk_buf.clear, { buf = buf })
	end
end

local function keymaps()
	local function map(lhs, fn, desc)
		vim.keymap.set("n", lhs, fn, { buffer = buf, desc = desc, nowait = true })
	end
	for _, lhs in ipairs({ "j", "<Down>" }) do
		map(lhs, function()
			step(1)
		end, "next card")
	end
	for _, lhs in ipairs({ "k", "<Up>" }) do
		map(lhs, function()
			step(-1)
		end, "previous card")
	end
	map("gg", function()
		go(true)
	end, "first card")
	map("G", function()
		go(false)
	end, "last card")
	map("<M-Left>", function()
		switch(-1, "Left")
	end, "previous section")
	map("<M-Right>", function()
		switch(1, "Right")
	end, "next section")
	map("<CR>", function()
		local e = current_entry()
		if e then
			section().list.enter(e, view)
		end
	end, "go there, or open it")
	-- Oil's - (packs/oil.lua) has no folder to open here.
	map("-", "<nop>")
end

function M.open()
	vim.g.sidebar = true
	local start = vim.env.PWD or vim.fn.getcwd()
	local git = vim.system({ "git", "-C", start, "rev-parse", "--path-format=absolute", "--git-common-dir" }, { text = true }):wait()
	local common = git.code == 0 and vim.trim(git.stdout) or ""
	state.folder = common:match("^(.+)/%.git$") or start
	buf = vim.api.nvim_get_current_buf()
	win = vim.api.nvim_get_current_win()
	vim.api.nvim_buf_set_name(buf, "sidebar://")
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	for option, value in pairs({
		number = false,
		relativenumber = false,
		signcolumn = "no",
		foldcolumn = "0",
		statuscolumn = "",
		cursorline = false,
		list = false,
		spell = false,
		wrap = false,
		scrolloff = cards.height,
	}) do
		vim.wo[win][option] = value
	end
	-- In normal mode the cursor takes the card's background, so it doesn't show where the terminal
	-- honors cursor colors; typing (a rename, a prompt) keeps the usual one.
	vim.o.guicursor = "n-v-sm:block-SidebarCursor,i-c-ci-ve:ver25,r-cr-o:hor20"
	keymaps()
	set_actions()

	local group = vim.api.nvim_create_augroup("Sidebar", { clear = true })
	-- A click on a card picks it.
	vim.api.nvim_create_autocmd("CursorMoved", {
		group = group,
		buffer = buf,
		callback = function()
			if state.moving then
				return
			end
			local index = cards.index_at(vim.api.nvim_win_get_cursor(win)[1])
			if index then
				select(index)
			else
				render()
			end
		end,
	})
	vim.api.nvim_create_autocmd({ "VimResized", "FocusGained" }, { group = group, callback = refresh })
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = group,
		callback = function()
			report("")
		end,
	})

	refresh()
	vim.uv.new_timer():start(2000, 2000, vim.schedule_wrap(refresh))
end

vim.api.nvim_create_user_command("Sidebar", M.open, { desc = "workspaces and agents sidebar" })

return M
