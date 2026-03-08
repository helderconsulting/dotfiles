vim.pack.add({
	"https://github.com/mfussenegger/nvim-dap",
	"https://github.com/igorlfs/nvim-dap-view",
})

local dap_ok, dap = pcall(require, "dap")
local utils = require("dap.utils")
local dapui_ok, dapui = pcall(require, "dap-view")
dap.set_log_level("WARN")
if dap_ok and dapui_ok then
	dapui.setup()
	dap.listeners.before.attach.dapui_config = function()
		dapui.open()
	end
	dap.listeners.before.launch.dapui_config = function()
		dapui.open()
	end
	dap.listeners.before.event_terminated.dapui_config = function()
		dapui.close()
	end
	dap.listeners.before.event_exited.dapui_config = function()
		dapui.close()
	end
end
for _, language in ipairs({ "typescript", "javascript" }) do
	dap.configurations[language] = {
		{
			type = "pwa-node",
			request = "launch",
			name = "Launch typescript file",
			runtimeExecutable = "node",
			runtimeArgs = {
				"--experimental-strip-types",
				"${file}",
			},
			rootPath = "${workspaceFolder}",
			program = "${file}",
			cwd = "${workspaceFolder}",
		},
		{

			type = "pwa-node",
			request = "launch",
			name = "Launch javascript file",
			program = "${file}",
			cwd = "${workspaceFolder}",
		},
		{
			type = "pwa-node",
			request = "attach",
			name = "Attach to Node process",
			processId = function()
				return utils.pick_process({
					filter = function(proc)
						local name = (proc.name or ""):lower()
						return name:find("node", 1, true) ~= nil
					end,
				})
			end,
			cwd = "${workspaceFolder}",
		},
		{
			type = "pwa-node",
			request = "attach",
			name = "Attach by port",
			port = function()
				local port = vim.fn.input("Debug port: ", "9229")
				return tonumber(port)
			end,
			cwd = "${workspaceFolder}",
			restart = true,
		},
	}
end

dap.configurations.c = {
	{
		name = "Launch file",
		type = "codelldb",
		request = "launch",
		-- this expects cmakelists to set the binary to "main"
		program = "${workspaceFolder}/build/main",
		cwd = "${workspaceFolder}",
		stopOnEntry = false,
	},
}

dap.adapters = {
	["pwa-node"] = {
		type = "server",
		host = "localhost",
		port = "${port}",
		executable = {
			command = "js-debug-adapter",
			args = {
				"${port}",
			},
		},
	},
	["codelldb"] = {
		type = "server",
		port = "${port}",
		executable = {
			command = vim.fn.stdpath("data") .. "/mason/bin/codelldb",
			args = { "--port", "${port}" },
		},
	},
}
vim.fn.sign_define("DapBreakpoint", { text = " ", texthl = "DapBreakpoint", numhl = "DapBreakpoint" })
vim.fn.sign_define("DapStoppedLine", { text = "", texthl = "DapStoppedLine", numhl = "DapStoppedLine" })
vim.fn.sign_define("DapStopped", { text = "", texthl = "DapStopped", numhl = "DapStopped" })
vim.fn.sign_define(
	"DapBreakpointRejected",
	{ text = "", texthl = "DapBreakpointRejected", numhl = "DapBreakpointRejected" }
)

local colors = {
	red = "#f7768e",
	green = "#9ece6a",
	orange = "#ff9e64",
	grey = "#565f89",
}
vim.api.nvim_set_hl(0, "DapBreakpoint", { fg = colors.red })
vim.api.nvim_set_hl(0, "DapStopped", { fg = colors.green, bold = true })
vim.api.nvim_set_hl(0, "DapBreakpointRejected", { fg = colors.orange })
vim.api.nvim_set_hl(0, "DapStoppedLine", { fg = "#2e3c64" })

local keymap = vim.keymap.set
local opts = { noremap = true, silent = true }
keymap("n", "<F2>", dap.continue, opts)
keymap("n", "<F3>", dap.step_over, opts)
keymap("n", "<F4>", dap.step_into, opts)
keymap("n", "<F5>", dap.step_out, opts)

vim.keymap.set("n", "<leader>b", dap.toggle_breakpoint, {
	desc = "toggle breakpoint",
})
