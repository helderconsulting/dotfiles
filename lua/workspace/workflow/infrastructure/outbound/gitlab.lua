local M = {}

M.query = [[
query($path: ID!, $branch: String!) {
  project(fullPath: $path) {
    mergeRequests(sourceBranches: [$branch], first: 1, sort: UPDATED_DESC) {
      nodes {
        iid webUrl title state detailedMergeStatus approved diffHeadSha targetBranch
        approvedBy { nodes { username } }
        reviewers { nodes { username mergeRequestInteraction { reviewState } } }
        headPipeline { id status finishedAt updatedAt path }
        discussions(first: 100) { nodes { id notes { nodes { system body resolvable resolved author { username } position { newPath oldPath newLine oldLine } } } } }
      }
    }
  }
}]]

local Gitlab = {}
Gitlab.__index = Gitlab

function M.new()
	return setmetatable({}, Gitlab)
end

function Gitlab:available()
	return vim.fn.executable("glab") == 1
end

local function api(root, args, done)
	local cmd = vim.list_extend({ "glab", "api" }, args)
	vim.system(cmd, { cwd = root, text = true }, vim.schedule_wrap(function(res)
		if res.code ~= 0 then
			return done(nil, vim.trim(res.stderr or "") ~= "" and vim.trim(res.stderr) or ("glab exited " .. res.code))
		end
		done(res.stdout)
	end))
end

local function ndjson(root, path, done)
	api(root, { "--paginate", "--output", "ndjson", path }, function(out, err)
		if not out then
			return done(nil, err)
		end
		local list = {}
		for line in out:gmatch("[^\n]+") do
			local ok, item = pcall(vim.json.decode, line)
			if ok then
				table.insert(list, item)
			end
		end
		done(list)
	end)
end

function Gitlab:merge_request(root, project, branch, done)
	api(root, { "graphql", "-f", "query=" .. M.query, "-f", "path=" .. project, "-f", "branch=" .. branch }, function(out, err)
		if not out then
			return done(nil, err)
		end
		local ok, data = pcall(vim.json.decode, out, { luanil = { object = true, array = true } })
		if not ok or type(data) ~= "table" then
			return done(nil, "bad json from gitlab graphql")
		elseif data.errors then
			return done(nil, tostring((data.errors[1] or {}).message or "gitlab graphql error"))
		end
		local found = (data.data or {}).project
		if not found then
			return done(nil, "gitlab has no project " .. project)
		end
		local nodes = found.mergeRequests and found.mergeRequests.nodes
		done({ node = nodes and nodes[1] or nil })
	end)
end

function Gitlab:failed_jobs(root, pipeline_id, done)
	ndjson(root, ("projects/:id/pipelines/%s/jobs?scope=failed&per_page=100"):format(pipeline_id), done)
end

function Gitlab:reply(root, iid, thread, body, done)
	local base = ("projects/:id/merge_requests/%s/discussions/%s"):format(iid, thread)
	api(root, { "--method", "POST", base .. "/notes", "-f", "body=" .. body }, function(_, err)
		done(err)
	end)
end

function Gitlab:resolve(root, iid, thread, done)
	local base = ("projects/:id/merge_requests/%s/discussions/%s"):format(iid, thread)
	api(root, { "--method", "PUT", base, "-F", "resolved=true" }, function(_, err)
		done(err)
	end)
end

return M
