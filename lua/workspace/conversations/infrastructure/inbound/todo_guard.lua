local base = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(vim.fs.abspath(arg[0]))))))
package.path = base .. "/?.lua;" .. base .. "/?/init.lua;" .. package.path
os.exit(require("workspace.conversations.infrastructure.inbound.todo_guard_cli").run())
