local function fake_ports()
	local clock = { now = 100 }
	local performed = {}
	local containers = {
		badge = function()
			return "2 up", "ok"
		end,
		place = function()
			return "local"
		end,
		docker = true,
		fetch = function(done)
			done({ { id = "c1", name = "web", container = "web-1", port = 8080, word = "running", kind = "ok", refs = { "c1" } } })
		end,
		show = function(source, mode)
			return { "web " .. mode }, "docker logs " .. source.id, true
		end,
		actions = {
			{
				"s",
				function(source, view)
					table.insert(performed, { source = source, view = view })
					return "started"
				end,
				"start",
				always = true,
			},
			{
				"x",
				function()
					return "removed"
				end,
				"remove",
				single = true,
			},
		},
	}
	local ports = {
		names = { "containers", "ports" },
		providers = {
			containers = containers,
			ports = {
				fetch = function(done)
					done(nil)
				end,
				show = function()
					return {}
				end,
				actions = {},
			},
		},
		usage = {
			in_use = function(refs)
				return refs ~= nil and refs[1] == "c1"
			end,
			project = function()
				return "proj"
			end,
		},
		desktops = { dir = "/tmp/desktops" },
		resources = require("workspace.infra.infrastructure.outbound.memory.resource_repository").new(),
		clock = function()
			return clock.now
		end,
	}
	return ports, performed
end

return function(t)
	local test, check = t.test, t.check

	test("composition builds the workbench and infra services", function()
		local services = require("workspace.composition_root").build(t.make_store(vim.fn.tempname()), {})
		check("workspace process is wired", services.workspace_process ~= nil)
		check("resource process is wired", services.resource_process ~= nil)
	end)

	test("workspace process saves, finds, lists and removes workspaces", function()
		local store = t.make_store(vim.fn.tempname())
		local wp = require("workspace.composition_root").build(store, {}).workspace_process
		check("nothing saved yet", #wp:list() == 0 and wp:find("w1") == nil)
		wp:save({ id = "w1", tab = 3, window = 1, root = "/p/a", mode = "full", panes = { sidebar = "10" }, opened = true })
		local found = wp:find("w1")
		check("finds the saved workspace", found ~= nil and found.id == "w1" and found.tab == 3 and found.root == "/p/a" and found.opened == true, found)
		check("keeps its panes", found ~= nil and found.panes.sidebar == "10", found and found.panes)
		check("finds by tab", wp:find_by_tab(3) ~= nil and wp:find_by_tab(3).id == "w1")
		check("finds by root", wp:find_by_root("/p/a") ~= nil and wp:find_by_root("/p/a").id == "w1")
		check("finds nothing for an unknown tab", wp:find_by_tab(9) == nil)
		wp:save({ id = "w2", tab = 4, root = "/p/b", mode = "nvim", panes = {} })
		check("lists every saved workspace", #wp:list() == 2)
		wp:remove("w1")
		check("removed workspace is gone", wp:find("w1") == nil and #wp:list() == 1)
		check("find with no id is nil", wp:find(nil) == nil)
	end)

	test("workspace process sizes panes for the mode and the terminal width", function()
		local wp = require("workspace.composition_root").build(t.make_store(vim.fn.tempname()), {}).workspace_process
		local full = wp:widths("full", 200)
		check("full layout keeps the sidebar ideal and shrinks the conversation", full.sidebar == 44 and full.conversation == 54 and full.editor == 100, full)
		local nvim = wp:widths("nvim", 200)
		check("nvim layout has no conversation", nvim.conversation == nil and nvim.sidebar == 44 and nvim.editor == 155, nvim)
		local narrow = wp:widths("full", 100)
		check("narrow full layout fits every pane into the room", narrow.sidebar == 22 and narrow.conversation == 26 and narrow.editor == 50, narrow)
		local limits = wp:limits()
		check("limits come from the sizes", limits.editor_min == 60 and limits.sidebar_min == 28 and limits.conversation_min == 32, limits)
	end)

	test("workspace process reports the roles a workspace is missing", function()
		local wp = require("workspace.composition_root").build(t.make_store(vim.fn.tempname()), {}).workspace_process
		local alive = function(id)
			return id ~= "2"
		end
		check("full mode wants every role", vim.deep_equal(wp:missing_roles("full", { sidebar = "1", conversation = "2" }, alive), { "conversation", "editor", "docker" }))
		check("nvim mode only wants sidebar and editor", vim.deep_equal(wp:missing_roles("nvim", {}, alive), { "sidebar", "editor" }))
		check("keeping closed roles lists only never-placed ones", vim.deep_equal(wp:missing_roles("full", { sidebar = "1", editor = "3", docker = "2" }, alive, true), { "conversation" }))
		check("wants follows the mode", wp:wants("nvim", "docker") == false and wp:wants("full", "docker") == true)
	end)

	test("workspace process keeps a pane only for the role it was given", function()
		local wp = require("workspace.composition_root").build(t.make_store(vim.fn.tempname()), {}).workspace_process
		wp:save({ id = "w1", panes = { sidebar = "7" } })
		check("keeps the pane in its role", wp:keeps("w1", "sidebar", "7") == true)
		check("does not keep it in another role", wp:keeps("w1", "editor", "7") == false)
		check("does not keep a different pane", wp:keeps("w1", "sidebar", "8") == false)
		check("does not keep for an unknown workspace", wp:keeps("missing", "sidebar", "7") == false)
		check("does not keep without a pane", wp:keeps("w1", "sidebar", nil) == false)
	end)

	test("workspace process resumes a session from the launch mode", function()
		local wp = require("workspace.composition_root").build(t.make_store(vim.fn.tempname()), {}).workspace_process
		check("a session mode resumes that session", wp:resume_session("session:abc123") == "abc123")
		check("a plain mode resumes nothing", wp:resume_session("full") == nil)
	end)

	test("workspace process sizes the panel and the diff layout", function()
		local wp = require("workspace.composition_root").build(t.make_store(vim.fn.tempname()), {}).workspace_process
		check("panel takes a quarter of the columns", wp:panel_width(100) == 25)
		check("panel is capped", wp:panel_width(200) == 35)
		check("panel has a floor", wp:panel_width(40) == 18)
		check("wide terminals diff side by side", wp:diff_layout(140) == "side-by-side")
		check("narrow terminals diff inline", wp:diff_layout(139) == "inline")
	end)

	test("resource process observes, toggles and reports a resource", function()
		local ports = fake_ports()
		local rp = require("workspace.infra.application.resource_process").new(ports)
		local up = rp:observe({ section = "containers", id = "c1", word = "running", kind = "ok" })
		check("an observed resource shows its word and kind", up.word == "running" and up.kind == "ok", up)
		local stopping = rp:toggle({ section = "containers", id = "c1" })
		check("toggling a running resource stops it", stopping.word == "stopping" and stopping.kind == "busy", stopping)
		local off = rp:observe({ section = "containers", id = "c2", word = "stopped", kind = "off" })
		check("an observed off resource shows off", off.word == "stopped" and off.kind == "off", off)
		local starting = rp:toggle({ section = "containers", id = "c2" })
		check("toggling an off resource starts it", starting.word == "starting" and starting.kind == "busy", starting)
		check("toggling an unknown resource does nothing", rp:toggle({ section = "containers", id = "nope" }) == nil)
	end)

	test("resource process marks entries by usage", function()
		local rp = require("workspace.infra.application.resource_process").new(fake_ports())
		local entries = { { refs = { "c1" } }, { refs = { "c9" } } }
		rp:mark_usage(entries)
		check("a used entry is in use", entries[1].word == "in use" and entries[1].kind == "ok", entries[1])
		check("an unused entry is unused", entries[2].word == "unused" and entries[2].kind == "off", entries[2])
	end)

	test("resource process lists sections with their badge and place", function()
		local rp = require("workspace.infra.application.resource_process").new(fake_ports())
		local section = rp:section("containers")
		check("section carries its name", section.name == "containers")
		check("section carries its badge", section.badge_word == "2 up" and section.badge_kind == "ok", section)
		check("section carries docker and place", section.docker == true and section.place == "local", section)
		local names = rp:section_names()
		names[1] = "changed"
		check("section names are a copy", rp:section_names()[1] == "containers")
	end)

	test("resource process fetches entries with details", function()
		local rp = require("workspace.infra.application.resource_process").new(fake_ports())
		local got
		rp:fetch("containers", function(list)
			got = list
		end)
		check("fetched entries carry their name and word", got ~= nil and got[1].name == "web" and got[1].word == "running", got)
		check("containers show their port as detail", got ~= nil and got[1].detail == "localhost:8080", got and got[1].detail)
		check("entries keep their source", got ~= nil and got[1].source.id == "c1")
		local none
		rp:fetch("ports", function(list)
			none = list
		end)
		check("a provider with nothing returns nil", none == nil)
	end)

	test("resource process shows and lists actions for a section", function()
		local rp = require("workspace.infra.application.resource_process").new(fake_ports())
		local show = rp:show("containers", { source = { id = "c1" } }, "logs")
		check("show carries the lines", show.lines[1] == "web logs", show)
		check("show carries the command", show.command == "docker logs c1", show)
		check("show carries the terminal flag", show.terminal == true, show)
		local actions = rp:actions("containers")
		check("actions keep their keys and labels", #actions == 2 and actions[1].key == "s" and actions[1].label == "start" and actions[2].key == "x", actions)
		check("actions keep their flags", actions[1].always == true and actions[2].single == true, actions)
	end)

	test("resource process performs an action on an entry", function()
		local ports, performed = fake_ports()
		local rp = require("workspace.infra.application.resource_process").new(ports)
		local result = rp:perform({
			section = "containers",
			key = "s",
			entry = { word = "running", kind = "ok", source = { id = "c1" } },
			view = "panel",
		})
		check("the action's result is returned", result == "started", result)
		check("the action gets the entry source with its word and kind", performed[1] ~= nil and performed[1].source.word == "running" and performed[1].source.kind == "ok", performed[1])
		check("the action gets the view", performed[1] ~= nil and performed[1].view == "panel")
		check("an unknown key performs nothing", rp:perform({ section = "containers", key = "z", entry = { source = { id = "c1" } }, view = nil }) == nil)
	end)

	test("resource process performs an always action without an entry", function()
		local ports, performed = fake_ports()
		local rp = require("workspace.infra.application.resource_process").new(ports)
		rp:perform({ section = "containers", key = "s", entry = nil, view = "panel" })
		check("the action runs with no source", performed[1] ~= nil and performed[1].source == nil and performed[1].view == "panel", performed[1])
	end)

	test("resource process reports docker project and desktops dir", function()
		local rp = require("workspace.infra.application.resource_process").new(fake_ports())
		check("docker project comes from usage", rp:docker_project() == "proj")
		check("desktops dir comes from desktops", rp:desktops_dir() == "/tmp/desktops")
	end)
end
