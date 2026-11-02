local tools = require("packs.tools")
local failures = {}

local function step(msg)
	io.write("\n==> ", msg, "\n")
end

local function fail(what)
	table.insert(failures, what)
	io.write("  ✗ ", what, "\n")
end

step("system tools")
for _, bin in ipairs(tools.binaries) do
	if vim.fn.executable(bin[1]) == 1 then
		io.write("  ✓ ", bin[1], "\n")
	elseif bin.optional then
		io.write("  - ", bin[1], " (optional, ", bin[2], ")\n")
	else
		fail(bin[1] .. " missing (" .. bin[2] .. ")")
	end
end

step("plugins from nvim-pack-lock.json")
vim.pack.add({}, { confirm = false })
for _, p in ipairs(vim.pack.get(nil, { info = false })) do
	io.write("  ✓ ", p.spec.name, "\n")
end

step("blink.cmp fuzzy matcher")
vim.cmd.packadd("blink.cmp")
require("blink.cmp.config").merge_with({ fuzzy = { implementation = "prefer_rust_with_warning" } })
local blink_done, blink_impl, blink_err = false, nil, nil
require("blink.cmp.fuzzy.download").ensure_downloaded(function(err, impl)
	blink_done, blink_impl, blink_err = true, impl, err
end)
vim.wait(120000, function()
	return blink_done
end, 200)
if blink_impl == "rust" or (blink_done and not blink_err and blink_impl == nil) then
	io.write("  ✓ prebuilt rust matcher\n")
else
	fail("blink.cmp matcher: " .. tostring(blink_err or "timed out"))
end

step("treesitter parsers")
vim.cmd.packadd("nvim-treesitter")
local ok_ts = require("nvim-treesitter").install(tools.parsers, { summary = true }):wait(900000)
if ok_ts == false then
	fail("treesitter parsers")
end

step("mason tools")
vim.cmd.packadd("mason.nvim")
local mason_done, mason_failed = false, {}
require("packs.mason").ensure_installed(function(failed)
	mason_done, mason_failed = true, failed
end)
vim.wait(1800000, function()
	return mason_done
end, 500)
if not mason_done then
	fail("mason tools timed out")
end
local mason_bad = {}
for _, name in ipairs(mason_failed) do
	mason_bad[name] = true
	fail("mason " .. name)
end
if mason_done then
	for _, name in ipairs(tools.mason) do
		if not mason_bad[name] then
			io.write("  ✓ ", name, "\n")
		end
	end
end

if #failures > 0 then
	step("done with " .. #failures .. " problem(s)")
	for _, f in ipairs(failures) do
		io.write("  ✗ ", f, "\n")
	end
	os.exit(1)
end
step("done")
os.exit(0)
