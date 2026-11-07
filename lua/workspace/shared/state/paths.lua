local M = {}

function M.new(home, state_home)
	local root = (state_home and state_home ~= "" and state_home or (home .. "/.local/state")) .. "/workspace"
	local p = {
		home = home,
		root = root,
		version = root .. "/version",
		log = root .. "/events.jsonl",
		trace = root .. "/trace.log",
		locks = root .. "/locks",
		drafts = root .. "/drafts",
		images = root .. "/images",
		provider = require("workspace.shared.providers").current().locations(home),
	}
	function p.dir(kind)
		return root .. "/" .. kind
	end
	function p.entity(kind, id)
		return root .. "/" .. kind .. "/" .. id .. ".json"
	end
	function p.lock(kind, id)
		return p.locks .. "/" .. kind .. "-" .. id
	end
	function p.draft(key)
		return p.drafts .. "/" .. key .. ".md"
	end
	return p
end

return M
