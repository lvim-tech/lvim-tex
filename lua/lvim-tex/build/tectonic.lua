-- lvim-tex: the tectonic backend.
--
-- Tectonic is the "one binary, no distribution" engine: it fetches the packages a document needs into
-- its own cache instead of relying on an installed TeX Live. That changes two things for us:
--
--   • It has NO rerun loop to delegate to (latexmk's job) — tectonic resolves cross-references itself,
--     internally, in one invocation. So a build here is genuinely one process, not a driver over one.
--   • `--keep-logs` is not optional for us: without it tectonic deletes the `.log` on success, and the
--     log IS our diagnostics source. `--synctex` likewise, or forward/inverse search has nothing to read.
--
-- Both flags therefore live in the default `args` (config.builders.tectonic) rather than being appended
-- here, so a user who edits that list can see why they matter — and health warns if they are gone.
--
---@module "lvim-tex.build.tectonic"

local config = require("lvim-tex.config")

local fn = vim.fn
local fs = vim.fs

local M = {}

M.name = "tectonic"

--- Is the backend usable on this machine?
---@return boolean ok, string? detail
function M.available()
    local bin = config.builders.tectonic.bin
    if not bin or bin == "" then
        return false, "builders.tectonic.bin is empty"
    end
    if fn.executable(bin) ~= 1 then
        return false, ("%s is not on PATH — install tectonic (it needs no TeX distribution)"):format(bin)
    end
    return true, nil
end

--- The argv for a BUILD of `ctx.target`.
---
--- `ctx.engine` (from a `% !TEX program` directive) is IGNORED: tectonic is its own engine and cannot
--- be pointed at pdflatex/xelatex/lualatex. Silently accepting the directive would mislead; the caller
--- reports it instead (health names the directive and which builder is actually in use).
---@param ctx { target: string, out_dir: string?, engine: string? }
---@return string[]
function M.argv(ctx)
    local spec = config.builders.tectonic
    local argv = { spec.bin }
    for _, arg in ipairs(spec.args) do
        argv[#argv + 1] = arg
    end
    if ctx.out_dir and spec.out_dir_flag then
        argv[#argv + 1] = spec.out_dir_flag:format(ctx.out_dir)
    end
    argv[#argv + 1] = ctx.target
    return argv
end

--- The directory the build runs in — the target's own, so relative `\input` and graphics resolve as
--- they do for a manual run.
---@param ctx { target: string }
---@return string
function M.cwd(ctx)
    return fs.dirname(ctx.target)
end

--- Environment additions. The same wide log wrap latexmk gets: tectonic drives a TeX engine underneath,
--- so its log is wrapped by the same `max_print_line` rule, and the parser depends on it.
---@return table<string, string>
function M.env()
    return {
        max_print_line = "10000",
        error_line = "254",
        half_error_line = "238",
    }
end

return M
