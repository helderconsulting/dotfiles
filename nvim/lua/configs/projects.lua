local projects_root = vim.g.projects_dir or (vim.env.HOME .. "/Code")

local function list_projects()
	local cmd
	if vim.fn.executable("fd") == 1 then
		cmd = { "fd", "-t", "d", "-d", "2", ".", projects_root }
	else
		cmd = { "find", projects_root, "-maxdepth", "2", "-type", "d" }
	end
	local ok, lines = pcall(vim.fn.systemlist, cmd)
	if not ok then
		return {}
	end
	local out = {}
	for _, line in ipairs(lines) do
		if line ~= projects_root then
			table.insert(out, line)
		end
	end
	table.sort(out)
	return out
end

local function open_project(path)
	if not path or path == "" then
		return
	end
	vim.cmd("cd " .. vim.fn.fnameescape(path))
	vim.cmd("edit .")
end

vim.api.nvim_create_user_command("Projects", function()
	local ok, fzf = pcall(require, "fzf-lua")
	if not ok then
		vim.notify("fzf-lua not available", vim.log.levels.WARN)
		return
	end
	local projects = list_projects()
	if #projects == 0 then
		vim.notify("No projects found in " .. projects_root, vim.log.levels.INFO)
		return
	end
	fzf.fzf_exec(projects, {
		prompt = "Projects> ",
		winopts = { height = 0.35, width = 1.00, row = 1.00, border = "none", preview = { hidden = "hidden" } },
		actions = {
			["enter"] = function(selected)
				open_project(selected and selected[1] or nil)
			end,
		},
	})
end, { desc = "List projects" })

vim.api.nvim_create_user_command("ProjectNew", function(opts)
	local name = opts.args
	if name == "" then
		name = vim.fn.input("New project name: ")
	end
	if name == "" then
		return
	end
	local path = projects_root .. "/" .. name
	if vim.fn.isdirectory(path) == 0 then
		vim.fn.mkdir(path, "p")
	end
	open_project(path)
end, { desc = "Create and open a new project", nargs = "?" })

vim.keymap.set("n", "<leader>pp", ":Projects<cr>", { desc = "list projects" })
vim.keymap.set("n", "<leader>pn", ":ProjectNew<cr>", { desc = "new project" })

vim.api.nvim_create_autocmd("VimEnter", {
	group = vim.api.nvim_create_augroup("ProjectsStart", { clear = true }),
	callback = function()
		if vim.fn.argc() == 0 and vim.api.nvim_buf_get_name(0) == "" then
			vim.cmd("Projects")
		end
	end,
})
