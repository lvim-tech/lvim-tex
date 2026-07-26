-- lvim-tex: the latexmk backend.
--
-- latexmk is the default because it already owns the part of the job that is genuinely hard: the
-- rerun loop. It decides how many times the engine must run, when biber/bibtex has to run in
-- between, and when cross-references have settled — so we deliberately delegate that instead of
-- reimplementing it (the plan's C11). What we do NOT delegate is SCHEDULING: `-pvc` (latexmk's own
-- watch mode) would mean a long-lived child process whose output we would have to interpret
-- continuously, so the rebuild loop stays ours (see lvim-tex.build) and every latexmk run here is a
-- single, finite invocation.
--
-- The `% !TEX program = …` directive names an ENGINE (xelatex, lualatex, …), not a backend; latexmk
-- drives all of them, so the directive becomes one more flag here rather than a different module.
--
---@module "lvim-tex.build.latexmk"

local config = require("lvim-tex.config")

local fn = vim.fn
local fs = vim.fs

local M = {}

M.name = "latexmk"

-- Engine name (from a `% !TEX program` directive) → the latexmk flag that selects it.
---@type table<string, string>
local ENGINE_FLAG = {
    pdflatex = "-pdf",
    xelatex = "-pdfxe",
    lualatex = "-pdflua",
    luatex = "-pdflua",
    dvipdfmx = "-pdfdvi",
}

--- Is the backend usable on this machine?
---@return boolean ok, string? detail  a health-ready explanation when not
function M.available()
    local bin = config.builders.latexmk.bin
    if not bin or bin == "" then
        return false, "builders.latexmk.bin is empty"
    end
    if fn.executable(bin) ~= 1 then
        return false, ("%s is not on PATH — install a TeX distribution (TeX Live / MacTeX / MiKTeX)"):format(bin)
    end
    return true, nil
end

--- The argv for a BUILD of `ctx.target`.
---@param ctx { target: string, out_dir: string?, engine: string? }
---@return string[]
function M.argv(ctx)
    local spec = config.builders.latexmk
    local argv = { spec.bin }
    -- An engine flag must come before the file; when the directive names an engine we drop the
    -- default `-pdf` so the two do not contradict each other.
    local engine_flag = ctx.engine and ENGINE_FLAG[ctx.engine] or nil
    for _, arg in ipairs(spec.args) do
        if not (engine_flag and arg == "-pdf") then
            argv[#argv + 1] = arg
        end
    end
    if engine_flag then
        argv[#argv + 1] = engine_flag
    end
    if ctx.out_dir and spec.out_dir_flag then
        argv[#argv + 1] = spec.out_dir_flag:format(ctx.out_dir)
    end
    argv[#argv + 1] = ctx.target
    return argv
end

--- The argv for a CLEAN. latexmk's own `-c` removes the auxiliary files and `-C` also removes the
--- final PDF, which is exactly the aux/full split the command exposes.
---@param ctx { target: string, out_dir: string?, full: boolean? }
---@return string[]
function M.clean_argv(ctx)
    local spec = config.builders.latexmk
    local argv = { spec.bin, ctx.full and "-C" or "-c" }
    if ctx.out_dir and spec.out_dir_flag then
        argv[#argv + 1] = spec.out_dir_flag:format(ctx.out_dir)
    end
    argv[#argv + 1] = ctx.target
    return argv
end

--- The directory the build runs in — the target's own directory, so relative `\input` paths and
--- `\includegraphics` resolve exactly as they do for a manual run.
---@param ctx { target: string }
---@return string
function M.cwd(ctx)
    return fs.dirname(ctx.target)
end

--- Environment additions for the run.
---@return table<string, string>
function M.env()
    return {
        -- TeX wraps its log at 79 columns by default, splitting messages mid-word. Raising the wrap
        -- width is what makes the log parser reliable instead of heuristic — its un-wrapping pass
        -- stays as a fallback for logs produced elsewhere.
        max_print_line = "10000",
        -- Show the full offending line in an error context rather than an abbreviation.
        error_line = "254",
        half_error_line = "238",
    }
end

return M
