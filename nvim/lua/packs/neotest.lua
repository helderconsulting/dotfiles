vim.pack.add({
	"https://github.com/nvim-neotest/neotest.git",
	"https://github.com/nvim-neotest/neotest-jest.git",
	"https://github.com/nvim-neotest/nvim-nio",
})
local neotest = require("neotest")
neotest.setup({
	adapters = {
		require("rustaceanvim.neotest"),
		require("neotest-jest")({
			jestConfigFile = function(file)
				if file:find("/packages/") or file:find("/libs/") then
					-- Matches "some/path/" in "some/path/src/"
					local match = file:match("(.*/[^/]+/)src")

					if match then
						return match .. "jest.config.ts"
					end
				end

				return vim.fn.getcwd() .. "/jest.config.ts"
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
