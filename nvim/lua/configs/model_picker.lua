local M = {}

local colors = { tag = "#A58BD3", model = "#77DD77", current = "#E0955A", detail = "#3F6F3F" }

function M.pick(entries, opts, done)
	if #entries == 0 then
		return vim.notify("nothing to pick from", vim.log.levels.WARN)
	end
	require("packs.fzf")
	local fzf = require("fzf-lua")
	local utils = require("fzf-lua.utils")
	local widths = { tag = 0, value = 0 }
	for _, e in ipairs(entries) do
		widths.tag = math.max(widths.tag, vim.fn.strdisplaywidth(e.tag))
		widths.value = math.max(widths.value, vim.fn.strdisplaywidth(e.value))
	end
	local lines, by_line = {}, {}
	for _, e in ipairs(entries) do
		local function pad(text, width)
			return text .. string.rep(" ", width - vim.fn.strdisplaywidth(text))
		end
		local detail = table.concat(vim.tbl_filter(function(s)
			return s and s ~= "" and s ~= e.value
		end, { e.label, e.description }), " · ")
		local line = ("%s  %s  %s"):format(
			utils.ansi_from_rgb(colors.tag, pad(e.tag, widths.tag)),
			utils.ansi_from_rgb(e.current and colors.current or colors.model, pad(e.value, widths.value)),
			utils.ansi_from_rgb(colors.detail, (e.current and "in use · " or "") .. detail)
		)
		table.insert(lines, line)
		by_line[vim.trim(utils.strip_ansi_coloring(line))] = e
	end
	fzf.fzf_exec(lines, {
		prompt = (opts.prompt or "model") .. "> ",
		fzf_opts = { ["--ansi"] = true, ["--no-sort"] = true, ["--header"] = opts.header or "enter pick" },
		actions = {
			["enter"] = function(selected)
				local e = selected and selected[1] and by_line[vim.trim(utils.strip_ansi_coloring(selected[1]))]
				if e then
					vim.schedule(function()
						done(e)
					end)
				end
			end,
		},
	})
end

function M.flatten(catalog, current)
	local out = {}
	for _, p in ipairs(catalog) do
		for _, m in ipairs(p.models or {}) do
			table.insert(out, {
				tag = p.provider,
				provider = p.provider,
				value = m.value,
				label = m.label,
				description = m.description,
				current = current and current.provider == p.provider and current.model == m.value or nil,
			})
		end
	end
	return out
end

function M.modes(current)
	return vim.tbl_map(function(m)
		return { tag = "mode", value = m.value, description = m.description, current = m.value == current or nil }
	end, require("workspace.models.runtime").modes)
end

return M
