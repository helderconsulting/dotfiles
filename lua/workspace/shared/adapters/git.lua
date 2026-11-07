local M = {}

function M.locate(cwd)
	local function git(...)
		local res = vim.system({ "git", "-C", cwd, ... }, { text = true }):wait()
		return res.code == 0 and vim.trim(res.stdout or "") or nil
	end
	local root = git("rev-parse", "--show-toplevel") or cwd
	local branch = git("branch", "--show-current")
	if not branch or branch == "" then
		branch = git("rev-parse", "--short", "HEAD")
	end
	local dir, common = git("rev-parse", "--path-format=absolute", "--git-dir"), git("rev-parse", "--path-format=absolute", "--git-common-dir")
	local repo = common and vim.fs.basename(common) == ".git" and vim.fs.dirname(common) or root
	return { cwd = cwd, root = root, repo = repo, branch = branch, worktree = dir ~= common and vim.fs.basename(root) or nil }
end

function M.repo_root(path)
	if not (path and vim.uv.fs_stat(path)) then
		return path
	end
	return M.locate(path).repo
end

function M.code_tree(root)
	local index = os.tmpname()
	os.remove(index)
	local function git(...)
		return vim.system({ "git", "-C", root, ... }, { text = true, env = { GIT_INDEX_FILE = index } }):wait()
	end
	local ok = git("read-tree", "HEAD").code == 0 and git("add", "-A").code == 0
	local res = ok and git("write-tree") or nil
	os.remove(index)
	return res and res.code == 0 and vim.trim(res.stdout or "") or nil
end

function M.default_branch(root)
	local res = vim.system({ "git", "-C", root, "symbolic-ref", "--short", "refs/remotes/origin/HEAD" }, { text = true }):wait()
	return res.code == 0 and vim.trim(res.stdout or ""):match("^[^/]+/(.+)$") or nil
end

return M
