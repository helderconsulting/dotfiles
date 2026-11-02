local M = {}

local workspaces = require("configs.workspaces")

local state_dir = (vim.env.XDG_STATE_HOME or (vim.env.HOME .. "/.local/state")) .. "/agent-status"
local review_dir = state_dir .. "/review"

local function real(path)
	return path and path ~= "" and (vim.uv.fs_realpath(path) or path) or nil
end

local function inside(folder, path)
	path = real(path)
	return path ~= nil and (path == folder or path:sub(1, #folder + 1) == folder .. "/")
end

local function read_lines(path)
	local f = io.open(path)
	if not f then
		return {}
	end
	local lines = {}
	for line in f:lines() do
		table.insert(lines, line)
	end
	f:close()
	return lines
end

local function decode(text)
	local ok, value = pcall(vim.json.decode, text or "", { luanil = { object = true, array = true } })
	return ok and type(value) == "table" and value or nil
end

function M.messages()
	local list = {}
	local lines = read_lines(state_dir .. "/threads.jsonl")
	for i = math.max(1, #lines - 500), #lines do
		local m = decode(lines[i])
		if m and m.at then
			table.insert(list, m)
		end
	end
	return list
end

local function names()
	local by_session, by_pane = {}, {}
	for _, w in ipairs(workspaces.running()) do
		for _, a in ipairs(w.agents or {}) do
			local name = a.title ~= "" and a.title or a.agent
			if a.session and a.session ~= "" then
				by_session[a.session] = name
			end
			by_pane[a.pane] = name
		end
	end
	return function(session, pane, fallback)
		return session and by_session[session] or pane and by_pane[pane] or fallback or "agent"
	end
end

-- filter: { session, pane, root } for one agent, or { folder } for a workspace.
function M.items(filter)
	local name = names()
	local items = {}
	local root = real(filter.root)
	local folder = real(filter.folder)
	local function mine(session, pane)
		if filter.session and session and session ~= "" then
			return session == filter.session
		end
		return filter.pane ~= nil and pane == filter.pane
	end
	local labels = {
		sent = { "review", "bad" },
		resolved = { "resolved", "ok" },
		ready = { "ready for review", "ok" },
		approved = { "approved", "ok" },
	}
	for _, m in ipairs(M.messages()) do
		if m.type == "review" then
			local label = labels[m.event]
			if label and ((root and real(m.root) == root) or (folder and inside(folder, m.root))) then
				local place = folder and (vim.fs.basename(m.root or "") .. "  ") or ""
				local card
				if m.path then
					local range = m.line1 == m.line2 and tostring(m.line1) or (m.line1 .. "-" .. m.line2)
					card = {
						place .. label[1] .. " " .. m.path .. ":" .. range,
						m.event == "resolved" and m.reply ~= "" and m.reply or m.text,
						workspaces.age(m.at) .. (m.agent and (" · " .. m.agent) or ""),
					}
				else
					card = {
						place .. label[1],
						m.note or (m.event == "approved" and "ready for a merge request" or ""),
						workspaces.age(m.at) .. (m.agent and (" · " .. m.agent) or ""),
					}
				end
				table.insert(items, {
					id = m.event .. m.at .. (m.id or ""),
					at = m.at,
					kind = label[2],
					card = card,
					comment = m.id and { root = m.root, id = m.id } or nil,
					root = m.root,
				})
			end
		else
			local from_me, to_me = mine(m.from_session, m.from_pane), mine(m.to_session, m.to_pane)
			local in_folder = folder and (inside(folder, m.from_root) or inside(folder, m.to_root))
			if from_me or to_me or in_folder then
				local from = name(m.from_session, m.from_pane, m.from_root and vim.fs.basename(m.from_root))
				local to = name(m.to_session ~= "" and m.to_session or nil, m.to_pane, (m.to or ""):gsub(" %[.*%]$", ""))
				local who = folder and (from .. " → " .. to) or from_me and ("to " .. to) or ("from " .. from)
				table.insert(items, {
					id = "m" .. m.at .. (m.from_pane or "") .. (m.to_pane or ""),
					at = m.at,
					kind = "busy",
					card = { who, m.text or "", workspaces.age(m.at) },
					pane = from_me and m.to_pane or m.from_pane,
				})
			end
		end
	end
	table.sort(items, function(a, b)
		return (a.at or 0) < (b.at or 0)
	end)
	return items
end

function M.review_counts(root)
	if not root or root == "" then
		return {}
	end
	local f = io.open(review_dir .. "/" .. (real(root):gsub("/", "%%")) .. ".json")
	local data = f and decode(f:read("*a"))
	if f then
		f:close()
	end
	local counts = { open = 0, resolved = 0 }
	for _, c in ipairs(data and data.comments or {}) do
		if c.status == "sent" then
			counts.open = counts.open + 1
		elseif c.status == "resolved" then
			counts.resolved = counts.resolved + 1
		end
	end
	return counts
end

function M.show_comment(root, id)
	vim.fn.mkdir(review_dir, "p")
	local f = io.open(review_dir .. "/show", "w")
	if f then
		f:write(vim.json.encode({ root = root, id = id, at = os.time() }))
		f:close()
	end
end

return M
