-- lvim-tex: the CUSTOM backend — a user-supplied command.
--
-- The escape hatch for a build this plugin does not model: a Makefile target, a project script, a
-- containerised toolchain. `config.builders.custom = { bin = "make", args = { "pdf" } }` and the build
-- lifecycle (single-flight, watchdog, log parsing, diagnostics, events) applies unchanged.
--
-- Two deliberate limits, both reported rather than worked around:
--   • There is no CLEAN. A custom command's clean-up is its own business and guessing at it (deleting
--     an out-dir we did not create) is exactly the kind of destructive guess this plugin does not make.
--     `:LvimTex clean` says so instead of doing something plausible.
--   • The `% !TEX program` ENGINE directive is not applied: only the user knows how their command takes
--     an engine, if at all. It is left for their own `args`.
--
-- The log still has to be findable: whatever the command does, it must leave `<jobname>.log` where the
-- plugin looks (beside the target, or in `out_dir` when one is set) or diagnostics will be empty. That
-- is stated in the README rather than hidden here.
--
---@module "lvim-tex.build.custom"

local config = require("lvim-tex.config")

local fn = vim.fn
local fs = vim.fs

local M = {}

M.name = "custom"

--- Is the backend usable? Unlike the built-in backends this one is unconfigured by default, so the
--- "not set up" case gets its own message — a missing `bin` is the expected state, not a broken install.
---@return boolean ok, string? detail
function M.available()
    local bin = config.builders.custom.bin
    if not bin or bin == "" then
        return false, "builders.custom.bin is not set — give it a command, e.g. { bin = 'make', args = { 'pdf' } }"
    end
    if fn.executable(bin) ~= 1 then
        return false, ("%s is not executable"):format(bin)
    end
    return true, nil
end

--- The argv for a BUILD. The target is appended LAST, after the user's own arguments, so a command that
--- takes its file as the final word works unchanged. A command that needs the file elsewhere can put a
--- literal path in `args` and ignore the appended one — that is why `append_target` exists.
---@param ctx { target: string, out_dir: string?, engine: string? }
---@return string[]
function M.argv(ctx)
    local spec = config.builders.custom
    local argv = { spec.bin }
    for _, arg in ipairs(spec.args) do
        argv[#argv + 1] = arg
    end
    if ctx.out_dir and spec.out_dir_flag then
        argv[#argv + 1] = spec.out_dir_flag:format(ctx.out_dir)
    end
    if spec.append_target ~= false then
        argv[#argv + 1] = ctx.target
    end
    return argv
end

--- The directory the build runs in — the target's own, as for every other backend.
---@param ctx { target: string }
---@return string
function M.cwd(ctx)
    return fs.dirname(ctx.target)
end

--- Environment additions: the wide log wrap, which any TeX engine underneath will honour.
---@return table<string, string>
function M.env()
    return {
        max_print_line = "10000",
        error_line = "254",
        half_error_line = "238",
    }
end

return M
