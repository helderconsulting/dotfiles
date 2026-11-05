local base = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0]))))
package.path = base .. "/?.lua;" .. base .. "/?/init.lua;" .. package.path

local command = table.remove(arg, 1)
local ok, cli = pcall(require, "workspace.cli." .. tostring(command))
if not ok then
	vim.uv.fs_write(2, "workspace: unknown command " .. tostring(command) .. "\n")
	os.exit(2)
end
os.exit(cli.run(arg) or 0)
