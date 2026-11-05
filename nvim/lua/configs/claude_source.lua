local source = {}

function source.new()
	return setmetatable({}, { __index = source })
end

function source:enabled()
	return require("configs.app").role == "conversation" and vim.fn.getcmdtype() == ":"
end

function source:get_completions(ctx, callback)
	local items = {}
	if not ctx.line:find("%s") then
		local kind = require("blink.cmp.types").CompletionItemKind.Function
		for _, name in ipairs(require("configs.link").commands()) do
			if name ~= "help" then
				table.insert(items, { label = name, kind = kind, insertText = name, labelDetails = { description = "claude" } })
			end
		end
	end
	callback({ items = items, is_incomplete_backward = false, is_incomplete_forward = false })
end

return source
