local Review = require("workspace.workflow.domain.review")

local Transcript = {}
Transcript.__index = Transcript

Transcript.filter = [[
fromjson? | select(.isSidechain != true and .isCompactSummary != true and (.isMeta != true or .origin.kind == "peer"))
| if .type == "user" and .origin.kind == "peer" then
	{k: "p", at: .timestamp, t: .origin.body, from: .origin.name}
elif .type == "user" then
	select((.message.content | type == "array" and any(.[]; .type == "tool_result")) | not)
	| {k: "p", at: .timestamp, t: (.message.content | if type == "string" then . else (map(select(.type == "text") | .text) | join("\n")) end)}
elif .type == "attachment" and .attachment.type == "queued_command" and .attachment.commandMode == "prompt" then
	if .attachment.origin.kind == "peer" then
		{k: "p", q: true, at: .timestamp, t: .attachment.origin.body, from: .attachment.origin.name}
	else
		{k: "p", q: true, at: .timestamp, t: (.attachment.prompt | if type == "string" then . else (map(select(.type == "text") | .text) | join("\n")) end)}
	end
elif .type == "queue-operation" and .operation == "enqueue" then
	{k: "e", at: .timestamp, t: (.content | if type == "string" then . elif type == "array" then (map(select(.type == "text") | .text) | join("\n")) else "" end)}
elif .type == "queue-operation" and (.operation == "remove" or .operation == "dequeue") then
	{k: "d", at: .timestamp, t: (.content | if type == "string" then . else null end)}
elif .type == "assistant" then
	.timestamp as $at
	| .message.content[]?
	| if .type == "text" then {k: "x", t: .text, at: $at}
	elif .type == "tool_use" then {k: "u", at: $at}
	else empty end
else empty end
]]

local skip = {
	"<command%-name>",
	"<command%-message>",
	"<local%-command",
	"%[Request interrupted",
	"This session is being continued",
	"Caveat:",
}

local function trim(s)
	return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

function Transcript.epoch(at)
	local y, mo, d, h, mi, sec = (at or ""):match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)")
	if not y then
		return nil
	end
	local lt, ut = os.date("*t"), os.date("!*t")
	ut.isdst = lt.isdst
	return os.time({ year = y, month = mo, day = d, hour = h, min = mi, sec = sec }) + os.time(lt) - os.time(ut)
end

function Transcript.prompt_text(raw)
	local text = trim(type(raw) == "string" and raw or "")
	if text == "" then
		return nil
	end
	for _, pattern in ipairs(skip) do
		if text:find("^" .. pattern) then
			return nil
		end
	end
	if text:find("^<task%-notification>") then
		return "a background task finished"
	end
	return trim((text:gsub("</?pasted_content[^>]*>", "")))
end

function Transcript.new(id, records)
	local self = setmetatable({ id = id, turns = {}, queue = {} }, Transcript)
	for _, record in ipairs(records or {}) do
		self:add(record)
	end
	return self
end

function Transcript:enqueue(record)
	table.insert(
		self.queue,
		{ text = record.t, prompt = Transcript.prompt_text(record.t), at = Transcript.epoch(record.at) }
	)
end

function Transcript:dequeue(record)
	local text = type(record.t) == "string" and record.t or nil
	for i, q in ipairs(self.queue) do
		if text == nil or q.text == text then
			return table.remove(self.queue, i)
		end
	end
	return table.remove(self.queue, 1)
end

function Transcript:queued()
	local out = {}
	for _, q in ipairs(self.queue) do
		if q.prompt then
			table.insert(out, q)
		end
	end
	return out
end

function Transcript:add(record)
	if record.k == "e" then
		return self:enqueue(record)
	elseif record.k == "d" then
		return self:dequeue(record)
	end
	local turn = self.turns[#self.turns]
	local prompt = record.k == "p" and Transcript.prompt_text(record.t)
	if prompt then
		table.insert(self.turns, {
			prompt = prompt,
			from = record.from,
			queued = record.q or nil,
			at = Transcript.epoch(record.at),
			reply = {},
		})
	elseif turn and record.k == "x" and type(record.t) == "string" then
		table.insert(turn.reply, record.t)
		turn.last = Transcript.epoch(record.at) or turn.last
	elseif turn and record.k == "u" then
		turn.reply = {}
		turn.last = Transcript.epoch(record.at) or turn.last
	end
end

function Transcript:seen_through(i, activity)
	local turn, after = self.turns[i], self.turns[i + 1]
	local mark = turn and (turn.last or turn.at) or 0
	if activity and (not after or math.floor(activity) <= (after.at or 0)) then
		return math.max(mark, activity)
	end
	return mark
end

function Transcript:count()
	return #self.turns
end

function Transcript:turn(i)
	return self.turns[i]
end

Transcript.receipt_window = 120

function Transcript:received(text, at)
	local prompt = Transcript.prompt_text(text)
	if not prompt then
		return true
	end
	for _, list in ipairs({ self.turns, self.queue }) do
		for i = #list, 1, -1 do
			local t = list[i]
			if (t.at or 0) < at - Transcript.receipt_window then
				break
			end
			if t.prompt == prompt then
				return true
			end
		end
	end
	return false
end

function Transcript.card_line(prompt)
	prompt = (prompt or ""):gsub("%[Image: source: [^%]]+%]", "[image]")
	local first = prompt:match("[^\n]+") or ""
	if Review.is_heading(first) then
		for raw in prompt:gmatch("[^\n]+") do
			local line = trim(raw)
			if line ~= "" and not Review.is_heading(line) and not Review.is_label(line) and not line:match("^>") then
				return line
			end
		end
	end
	return first
end

return Transcript
