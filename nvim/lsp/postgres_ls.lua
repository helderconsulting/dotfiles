---@brief
---
--- https://github.com/supabase-community/postgres-language-server
---
--- Postgres-specific LSP: syntax, linting, typechecking and completion
--- against a real database schema.
---
--- Requires a `postgres-language-server.jsonc` at the project root with a
--- `db` connection (host/port/username/password/database, or a
--- `connectionString`) for schema-aware features to work.

---@type vim.lsp.Config
return {
	cmd = { "postgres-language-server", "lsp-proxy" },
	filetypes = { "sql" },
	root_markers = { "postgres-language-server.jsonc" },
	workspace_required = true,
}
