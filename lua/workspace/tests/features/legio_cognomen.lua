local Legio = require("workspace.legio.domain.legio")
local LegioDto = require("workspace.legio.application.dto.legio_dto")
local legio_dto_mapper = require("workspace.legio.application.mappers.legio_dto_mapper")
local legio_mapper = require("workspace.legio.presentation.mappers.legio_view_mapper")
local legio_record_mapper = require("workspace.legio.infrastructure.outbound.filesystem.legio_record_mapper")
local legio_repository = require("workspace.legio.infrastructure.outbound.filesystem.legio_repository")

return function(t)
	local test, check, make_store = t.test, t.check, t.make_store

	local function annales_text(legio)
		local out = {}
		for _, entry in ipairs(legio.annales) do
			table.insert(out, type(entry) == "table" and entry.text or tostring(entry))
		end
		return table.concat(out, "\n")
	end

	local function occurrences(text, word)
		local n, from = 0, 1
		while true do
			local s, e = text:find(word, from, true)
			if not s then
				return n
			end
			n, from = n + 1, e + 1
		end
	end

	local function finish(legio, n, at)
		legio:deploy("e" .. n, "expeditio " .. n, "c" .. n, at)
		return legio:discharge("expeditio " .. n, at)
	end

	local function finish_many(legio, count)
		for n = 1, count do
			finish(legio, n, 1 + n)
		end
		return legio
	end

	test("a legio that has finished two expeditiones has no cognomen yet", function()
		local legio = finish_many(Legio.raise(Legio.standing[1], 1), 2)
		check("two discharges are counted", legio.expeditiones == 2, legio.expeditiones)
		check("the second discharge doesn't earn it", legio.cognomen == nil, legio.cognomen)
		check("the annales don't record a cognomen", occurrences(annales_text(legio), "earned the cognomen") == 0, annales_text(legio))
	end)

	test("the third finished expeditio earns the cognomen Victrix and the annales record it", function()
		local legio = Legio.raise(Legio.standing[1], 1)
		finish_many(legio, 2)
		finish(legio, 3, 10)
		check("the third discharge earns Victrix", legio.cognomen == "Victrix", legio.cognomen)
		check("the annales record it", occurrences(annales_text(legio), "earned the cognomen Victrix") == 1, annales_text(legio))
		check("the name stays", legio.name == "Legio X Rapax")
	end)

	test("the cognomen is kept after later expeditiones and not earned twice", function()
		local legio = finish_many(Legio.raise(Legio.standing[1], 1), 6)
		check("six discharges are counted", legio.expeditiones == 6, legio.expeditiones)
		check("the cognomen is still Victrix", legio.cognomen == "Victrix", legio.cognomen)
		check("the annales record the earning once", occurrences(annales_text(legio), "earned the cognomen") == 1, annales_text(legio))
	end)

	test("the record mapper round-trips the cognomen and the expeditiones counter", function()
		local legio = finish_many(Legio.raise(Legio.standing[1], 1), 3)
		local record = legio_record_mapper.to_record(legio)
		check("the record holds the cognomen and the counter", record.cognomen == "Victrix" and record.expeditiones == 3, record)
		local back = legio_record_mapper.to_domain(record)
		check("the domain object comes back with them", back.cognomen == "Victrix" and back.expeditiones == 3, { back.cognomen, back.expeditiones })
		check("and it can't earn it again", back:earns_cognomen() == false)
	end)

	test("a stored legio keeps its cognomen", function()
		local store = make_store(vim.fn.tempname())
		local repo = legio_repository.new(store)
		local legio = finish_many(Legio.raise(Legio.standing[1], 1), 3)
		repo:save(legio)
		local stored = repo:get(legio.id)
		check("it is stored with its cognomen and counter", stored ~= nil and stored.cognomen == "Victrix" and stored.expeditiones == 3, stored and { stored.cognomen, stored.expeditiones })
	end)

	test("the legio's dto carries its cognomen", function()
		local legio = finish_many(Legio.raise(Legio.standing[1], 1), 3)
		local dto = legio_dto_mapper.to_legio_dto(legio, nil, nil)
		check("it is still a LegioDto", LegioDto.is(dto))
		check("the dto has the cognomen", dto.cognomen == "Victrix", dto.cognomen)
	end)

	test("a legio with a cognomen shows Legio X Rapax Victrix on its sidebar card", function()
		local entries = legio_mapper.to_legio_entries({
			{ id = "x-rapax", name = "Legio X Rapax", cognomen = "Victrix", munus = "implement", roles = { "faber", "probator", "censor" }, deployed = false },
			{ id = "iv-obsidionalis", name = "Legio IV Obsidionalis", munus = "test and break", roles = { "probator", "censor" }, deployed = false },
		})
		check("the card's name is Legio X Rapax Victrix", entries[1].card[1] == "Legio X Rapax Victrix", entries[1].card[1])
		check("a legio without one keeps its plain name", entries[2].card[1] == "Legio IV Obsidionalis", entries[2].card[1])
	end)
end
