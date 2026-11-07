local Legio = require("workspace.legio.domain.legio")
local muster = require("workspace.legio.domain.muster")

-- the orders muster.plan gives each post, with the commander_commits option passed through
local function plan_with(commander_commits)
	local legio = Legio.raise(Legio.standing[1], 1)
	local expeditio = { id = "e1", title = "agentd sdk", root = "/p", mandata = { { id = "m1", title = "split", text = "# split", state = "open" } } }
	local ids = 0
	return muster.plan(legio, expeditio, {
		mandata = expeditio.mandata,
		taken_names = {},
		contubernia = {},
		base = "main",
		at = 1,
		random = function(a)
			return a
		end,
		done_command = "todo",
		commander_commits = commander_commits,
		new_id = function()
			ids = ids + 1
			return "id" .. ids
		end,
		centuria_id = function()
			return "c1"
		end,
		new_contubernium_id = function()
			return "t1"
		end,
	})
end

local function prompt_of(plan, post)
	for _, p in ipairs(plan.posts) do
		if p.post == post then
			return p.prompt
		end
	end
end

local function member_prompt(plan)
	for _, p in ipairs(plan.posts) do
		if p.post == "faber" or p.post == "probator" or p.post == "censor" then
			return p.prompt
		end
	end
end

return function(t)
	local test, check = t.test, t.check

	test("the decanus, with commander_commits off, creates his worktree and branch, tells his milites the path, and ships", function()
		local decanus = prompt_of(plan_with(false), "decanus") or ""
		check("the decanus creates his worktree and branch", decanus:find("Create your worktree and branch.", 1, true) ~= nil, decanus)
		check("the decanus tells his milites the path to his worktree", decanus:find("Tell your milites the path to your worktree.", 1, true) ~= nil, decanus)
		check("the decanus commits, pushes and opens the merge request himself", decanus:find("Commit, push and open the merge request yourself.", 1, true) ~= nil, decanus)
	end)

	test("a member, with commander_commits off, works only in the decanus's worktree and never creates, commits or pushes", function()
		local member = member_prompt(plan_with(false)) or ""
		check("the member works only in the decanus's worktree", member:find("Work only in the decanus's worktree.", 1, true) ~= nil, member)
		check("the member never creates a worktree, commits or pushes", member:find("Never create a worktree, commit or push.", 1, true) ~= nil, member)
		check("the member has no worktree of his own", member:find("own git worktree", 1, true) == nil, member)
	end)

	test("the decanus, with commander_commits on, creates no worktree, commits nothing, and leaves the changes in the checkout", function()
		local decanus = prompt_of(plan_with(true), "decanus") or ""
		check("the decanus does not create a worktree and does not commit", decanus:find("Don't create a worktree and don't commit: the commander commits.", 1, true) ~= nil, decanus)
		check("the decanus leaves his changes in the checkout and tells his milites where", decanus:find("Leave your changes in the checkout, and tell your milites the path to it.", 1, true) ~= nil, decanus)
		check("the decanus is not told to open the merge request", decanus:find("open the merge request", 1, true) == nil, decanus)
		check("the decanus is not told to create his worktree", decanus:find("Create your worktree and branch.", 1, true) == nil, decanus)
	end)

	test("a member, with commander_commits on, works in the checkout and never creates a worktree, commits or pushes", function()
		local member = member_prompt(plan_with(true)) or ""
		check("the commander commits and the member works in the checkout", member:find("The commander commits: work in the checkout.", 1, true) ~= nil, member)
		check("the member never creates a worktree, commits or pushes", member:find("Never create a worktree, commit or push.", 1, true) ~= nil, member)
		check("the member is not sent to the decanus's worktree", member:find("Work only in the decanus's worktree.", 1, true) == nil, member)
	end)
end
