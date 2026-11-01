vim.pack.add({
	"https://github.com/folke/which-key.nvim",
})

local modifiers = { C = "Ctrl", M = "Alt", A = "Alt", D = "Cmd", S = "Shift" }
local names = { cr = "Enter", nl = "Enter", bs = "Backspace", esc = "Esc", space = "Space", tab = "Tab" }
local function label(key)
	local inner = key:match("^<(.+)>$")
	if not inner then
		return key
	end
	local mods = {}
	while inner:match("^%a%-.") do
		mods[inner:sub(1, 1):upper()] = true
		inner = inner:sub(3)
	end
	local base = names[inner:lower()] or inner
	if #base == 1 and base:match("%a") then
		base = mods.S and base:upper() or (mods.C and base:lower() or base)
		mods.S = nil
	end
	local words = {}
	for _, m in ipairs({ "C", "M", "A", "D", "S" }) do
		if mods[m] then
			table.insert(words, modifiers[m])
		end
	end
	table.insert(words, base)
	return table.concat(words, " + ")
end

require("which-key").setup({
	icons = {
		mappings = false,
	},
	replace = {
		key = {
			function(lhs)
				return table.concat(vim.tbl_map(label, require("which-key.util").keys(lhs)), " ")
			end,
		},
	},
	-- In the docker view only its own actions (configs/docker.lua), not the editor's.
	filter = function(mapping)
		return not vim.b.docker_view or (mapping.buffer or 0) ~= 0
	end,
	-- Its default triggers plus terminal mode, which only has prefixed mappings in the docker view's
	-- terminals (configs/docker.lua): without it the 50ms timeoutlen ends a leader there before the
	-- next key comes.
	triggers = {
		{ "<auto>", mode = "nxsot" },
	},
})
