return function(t)
	local test, check, make_store = t.test, t.check, t.make_store

	test("a sent mandatum is finished and handed on by its holder", function()
		local root = vim.fn.tempname()
		local store = make_store(root)
		local services = require("workspace.composition_root").build(store, { clock = os.time })
		local process = services.mandatum_process
		local id = process:add_mandatum({ root = "/p", expeditio_title = "x", title = "T", description = "d", criteria = { "Given a, when b, then c" }, from = "you" })
		check("assigning works", process:assign({ mandatum_id = id, miles_id = "s1" }))
		check("sending works", process:send({ mandatum_id = id, miles_id = "s1" }))
		check("it is sent", process:mandatum(id).state == "sent")
		check("handing a sent mandatum on works", process:hand({ mandatum_id = id, from = "s1", to = "s2" }))
		check("the new holder finishes it", process:finish({ mandatum_id = id, note = "done" }) and process:mandatum(id).state == "done")
		vim.fn.delete(root, "rf")
	end)
end
