local M = {}

function M.deployed(ports)
	local out = {}
	for _, legio in ipairs(ports.legiones:all()) do
		if legio:is_deployed() and legio.centuria then
			local centuria = ports.centuriae:get(legio.centuria)
			if centuria and centuria.legio == legio.id then
				local contubernia = {}
				for _, id in ipairs(centuria.contubernia or {}) do
					local contubernium = ports.contubernia_records:get(id)
					if contubernium then
						table.insert(contubernia, contubernium)
					end
				end
				table.insert(out, {
					legio = legio.id,
					centuria = centuria,
					cohors = centuria.cohors and ports.cohortes:get(centuria.cohors) or nil,
					contubernia = contubernia,
				})
			end
		end
	end
	return out
end

function M.of(miles_id, deployed, miles)
	for _, d in ipairs(deployed) do
		local post = d.centuria:post_of(miles_id)
		if post then
			return d.legio, post, d
		end
	end
	for _, d in ipairs(deployed) do
		if d.cohors and d.cohors.primus_pilus == miles_id and miles and d.cohors:is_led_by(miles) then
			return d.legio, "primus pilus", d
		end
	end
	for _, d in ipairs(deployed) do
		for _, contubernium in ipairs(d.contubernia) do
			local member = contubernium:member_for(miles_id)
			if member then
				return d.legio, member.role, d
			end
		end
	end
end

return M
