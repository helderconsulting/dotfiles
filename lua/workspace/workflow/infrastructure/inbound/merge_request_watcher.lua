local M = {}

function M.watch(services)
	local process = services.merge_request_process
	if not process:available() then
		return
	end
	vim.uv.new_timer():start(2000, process.interval * 1000, vim.schedule_wrap(function()
		process:poll(services.roster:all())
	end))
end

return M
