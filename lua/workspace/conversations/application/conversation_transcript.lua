local mapper = require("workspace.conversations.application.mappers.inquiry_dto_mapper")

local ConversationTranscript = {}
ConversationTranscript.__index = ConversationTranscript

local M = {}

function M.new(ports)
	return setmetatable({ transcripts = ports.transcripts }, ConversationTranscript)
end

function ConversationTranscript:get(agent_id)
	local transcript = self.transcripts.get(agent_id)
	return transcript and mapper.to_transcript_dto(transcript) or nil
end

function ConversationTranscript:seen_through(agent_id, turn, activity)
	local transcript = self.transcripts.get(agent_id)
	return transcript and transcript:seen_through(turn, activity) or 0
end

function ConversationTranscript:received(agent_id, text, at)
	local transcript = self.transcripts.get(agent_id)
	return transcript ~= nil and transcript:received(text, at)
end

return M
