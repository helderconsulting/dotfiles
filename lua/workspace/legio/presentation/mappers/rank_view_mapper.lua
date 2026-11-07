local M = {}

M.chevron = "▴"

local tones = { "off", "busy", "ok" }

function M.insignia(level)
	return M.chevron:rep(level or 1)
end

function M.tone(level)
	return tones[level] or tones[#tones]
end

function M.badge(standing)
	return M.insignia(standing.level) .. " " .. standing.rank
end

function M.progress(standing)
	if not standing.next then
		return nil
	end
	local unit = standing.unit == "expeditiones" and " expeditiones" or ""
	return ("%d/%d%s to %s"):format(standing.done, standing.needed, unit, standing.next)
end

function M.to_rank_label(standing)
	local progress = M.progress(standing)
	return M.badge(standing) .. (progress and (" · " .. progress) or "")
end

function M.to_rank_row(standing)
	local progress = M.progress(standing)
	return {
		segments = {
			{ M.badge(standing), M.tone(standing.level) },
			progress and { " · " .. progress, "off" } or nil,
		},
	}
end

local function needs(step)
	if step.mandata == 0 then
		return ""
	end
	local parts = { step.mandata .. " mandata" }
	if step.expeditiones then
		table.insert(parts, step.expeditiones .. " expeditiones")
	end
	return " (" .. table.concat(parts, " or ") .. ")"
end

function M.to_rank_legend(ladder)
	local parts = {}
	for _, step in ipairs(ladder or {}) do
		table.insert(parts, M.insignia(step.level) .. " " .. step.rank .. needs(step))
	end
	return table.concat(parts, "  ")
end

return M
