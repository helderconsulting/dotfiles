local Draft = {}
Draft.__index = Draft

function Draft.new(target, text, images, mtime, created)
	return setmetatable(
		{ target = target, text = text or "", images = images or {}, mtime = mtime, created = created },
		Draft
	)
end

local function folder_key(target)
	return (target.cwd or ""):gsub("[^%w]", "-")
end

function Draft.key(target)
	if target.expeditio then
		return "expeditio-" .. (target.expeditio == true and folder_key(target) or target.expeditio)
	end
	if target.mandatum then
		return "mandatum-"
			.. (target.mandatum == true and (target.in_expeditio or folder_key(target)) or target.mandatum)
	end
	if target.agent then
		return target.agent
	end
	return "new" .. (target.cwd or ""):gsub("[^%w]", "-")
end

function Draft.starts_session(target)
	return target ~= nil and not target.agent and not target.mandatum and not target.expeditio
end

function Draft:is_empty()
	return self.text:match("^%s*$") ~= nil
end

function Draft:first_line()
	return self.text:match("[^\n]+") or "empty"
end

function Draft:next_image()
	local n = 1
	while self.images[tostring(n)] do
		n = n + 1
	end
	return n
end

function Draft:attach(path)
	local n = self:next_image()
	self.images[tostring(n)] = path
	return "[Image #" .. n .. "]"
end

function Draft.expand(text, images)
	return (
		text:gsub("%[Image #(%d+)%]", function(n)
			local path = images and images[n]
			return path and ("[Image: source: " .. path .. "]") or nil
		end)
	)
end

function Draft:message()
	return Draft.expand(self.text, self.images)
end

function Draft:with_review(prompt)
	if prompt and prompt ~= "" then
		self.text = (self.text .. "\n\n" .. prompt):gsub("^%s+", "")
	end
	return self
end

function Draft:delivery(agent)
	if self.target.expeditio then
		return "expeditio"
	elseif self.target.mandatum then
		return "mandatum"
	end
	if not self.target.agent then
		return "start"
	end
	if not agent or not agent:is_running() then
		return "resume"
	end
	if agent:is_busy() then
		return "hold"
	end
	local ok, why = agent:can_receive()
	if not ok then
		return nil, why
	end
	return "message"
end

function Draft:is_new_session()
	return self.target.agent == nil
end

return Draft
