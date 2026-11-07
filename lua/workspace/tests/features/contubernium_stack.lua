local Contubernium = require("workspace.legio.domain.contubernium")
local Mandatum = require("workspace.workflow.domain.mandatum")
local Expeditio = require("workspace.workflow.domain.expeditio")
local expeditio_dto_mapper = require("workspace.workflow.application.mappers.expeditio_dto_mapper")
local expeditio_view_mapper = require("workspace.workflow.presentation.mappers.expeditio_view_mapper")
local ContuberniumStackMemberDto = require("workspace.legio.application.dto.contubernium_stack_member_dto")
local miles_view_mapper = require("workspace.legio.presentation.mappers.miles_view_mapper")

return function(t)
	local test, check = t.test, t.check

	test("a todo's card lists its contubernium in stack order", function()
		local store = t.make_store(vim.fn.tempname())
		local services = require("workspace.composition_root").build(store)
		local Miles = require("workspace.legio.domain.miles")
		store:update(Miles, "id-a", function(a)
			a.branch, a.root, a.state = "feat/base", "/p", "working"
		end)
		store:update(Miles, "id-b", function(a)
			a.branch, a.root, a.state = "feat/api", "/p", "stopped"
		end)
		local contubernium = Contubernium.make("t1", "ab12", "/p", "main", { "id-a", "id-b", "id-c" }, 1, "otter")
		require("workspace.legio.infrastructure.outbound.filesystem.contubernium_repository").new(store):save(contubernium)
		local dtos = services.roster:contubernium_stack("ab12")
		check("the roster gives one ContuberniumStackMemberDto per member", #dtos == 3 and ContuberniumStackMemberDto.is(dtos[1]))
		local rows = miles_view_mapper.to_contubernium_stack_rows(dtos)
		local function text(row)
			local out = ""
			for _, seg in ipairs(row.segments) do
				out = out .. seg[1]
			end
			return out
		end
		check("lead first with branch and state", text(rows[1]):find("^1%. ash %(lead%) · feat/base · ") ~= nil)
		check("a member without a session is gone", text(rows[3]) == "3. cedar · no branch · gone" and rows[3].segments[3][2] == "off")
		check("no contubernium, no rows", #services.roster:contubernium_stack("ffff") == 0)

		local older = Contubernium.make("t0", "ab12", "/p", "main", { "id-x", "id-y" }, 0, "heron")
		check("the newest contubernium on a todo wins", Contubernium.for_todo({ older, contubernium }, "ab12") == contubernium)
		check("no contubernium for other todos", Contubernium.for_todo({ older, contubernium }, "ffff") == nil)

		local todo = Mandatum:new({ id = "ab12", state = "sent", expeditio = "e1", headline = "Split the api", assignee = "id-a", sent_at = 1, created = 1 })
		local dto = expeditio_dto_mapper.to_mandatum_dto(todo)
		local card = expeditio_view_mapper.to_mandatum_card(dto, function()
			return "ash"
		end, 2, rows)
		check("the card keeps its three lines and adds the stack", #card == 6 and card[4] == rows[1] and card[6] == rows[3])
		check("a mandatum without a contubernium keeps three lines", #expeditio_view_mapper.to_mandatum_card(dto, function()
			return "ash"
		end, 2) == 3)

		local epic = Expeditio:new({ id = "e1", title = "api", root = "/p" })
		epic:hydrate({ todo })
		local item = expeditio_view_mapper.to_thread(expeditio_dto_mapper.to_expeditio_dto(epic), function()
			return "ash"
		end, 2, function(id)
			return id == "ab12" and rows or nil
		end).items[1]
		check("the expeditio thread passes the stack to the card", item and #item.card == 6)
	end)
end
