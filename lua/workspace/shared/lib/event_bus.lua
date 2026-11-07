local M = {}

function M.new(on_error)
	local subs = {}
	local bus = {}

	function bus.on(topic, fn)
		subs[topic] = subs[topic] or {}
		table.insert(subs[topic], fn)
		return function()
			bus.off(topic, fn)
		end
	end

	function bus.off(topic, fn)
		for i, f in ipairs(subs[topic] or {}) do
			if f == fn then
				table.remove(subs[topic], i)
				return
			end
		end
	end

	function bus.emit(topic, payload)
		local list = {}
		for i, fn in ipairs(subs[topic] or {}) do
			list[i] = fn
		end
		for _, fn in ipairs(list) do
			local ok, err = pcall(fn, payload)
			if not ok and on_error then
				on_error(topic, err)
			end
		end
	end

	return bus
end

return M
