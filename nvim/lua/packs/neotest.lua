vim.pack.add({
	"https://github.com/nvim-neotest/neotest.git",
	"https://github.com/nvim-neotest/neotest-jest.git",
	"https://github.com/marilari88/neotest-vitest.git",
	"https://github.com/fredrikaverpil/neotest-golang",
	"https://github.com/nvim-neotest/nvim-nio",
})
local neotest = require("neotest")
neotest.setup({
	adapters = {
		require("rustaceanvim.neotest"),
		require("neotest-golang")({
			go_test_args = { "-v", "-race", "-count=1", "-timeout=60s" },
			dap_go_enabled = true,
			runner = "gotestsum",
		}),
		require("neotest-jest")({
			isTestFile = function(path)
				return path:match("%.e2e.ts$") or path:match("%.spec.ts$")
			end,
			jestConfigFile = function(file)
				if file:find("/packages/") or file:find("/libs/") or file:find("/apps/") then
					local match = file:match("(.*/[^/]+/)src")

					if match then
						return match .. "jest.config.ts"
					end
				end

				return vim.fn.getcwd() .. "/jest.config.ts"
			end,
		}),
		require("neotest-vitest")({
			is_test_file = function(path)
				return path:match("%.test%.[jt]sx?$") ~= nil
			end,
			cwd = function(file)
				local root = vim.fn.getcwd()
				local found = vim.fs.find(function(name)
					return name:match("^vitest%.config%.[cm]?[jt]s$") or name:match("^vite%.config%.[cm]?[jt]s$")
				end, { path = vim.fs.dirname(file), upward = true, stop = vim.fs.dirname(root) })[1]

				if found then
					return vim.fs.dirname(found)
				end

				return root
			end,
		}),
	},
})

vim.keymap.set("n", "<leader>tr", ":Neotest run<cr>", { desc = "Run test" })
vim.keymap.set("n", "<leader>td", function()
	neotest.run.run({ strategy = "dap" })
end, { desc = "Debug run test" })
vim.keymap.set("n", "<leader>to", ":Neotest output<cr>", { desc = "Show test output" })
vim.keymap.set("n", "<leader>ts", ":Neotest summary<cr>", { desc = "Summarize test" })
vim.keymap.set("n", "<leader>ta", function()
	neotest.run.run({ suite = true })
end, { desc = "run all tests" })
