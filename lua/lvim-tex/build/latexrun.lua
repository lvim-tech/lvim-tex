-- lvim-tex: the latexrun backend.
--
-- latexrun is the "one command, quiet output" driver: like latexmk it owns the rerun loop (it re-runs
-- the engine and bibtex until the cross-references settle, up to `--max-iterations`), so that part is
-- delegated for the same reason it is delegated to latexmk. What is DIFFERENT is where the files go,
-- and that difference is the whole integration:
--
--   • `-O <dir>` is the object directory, which latexrun passes straight to the engine as
--     `-output-directory`. The `.log`, the `.synctex.gz`, the `.fls` and every aux file land THERE.
--     Its default is `latex.out` — a directory this plugin knows nothing about, so we always pass our
--     own, even when "our own" is the source directory (`.`). Leaving the default would leave the log
--     parser, forward search and the watch set all reading files that are not where they look.
--   • `-o <file>` is where the finished PDF is COPIED once the loop converges. Its default is the
--     input's basename in the CURRENT directory, which is not `<out_dir>/<jobname>.pdf` — the one path
--     `root.pdf` derives and the viewer, `:LvimTex info` and health all trust. So it is named
--     explicitly, from the same two pieces `root.pdf` uses.
--
-- latexrun already passes `-interaction nonstopmode -recorder` to the engine itself. What it does NOT
-- pass is `-file-line-error` (the `file:line: message` shape the log parser keys on) or `-synctex=1`,
-- so both live in the default `--latex-args` — ONE argv word, which latexrun splits with POSIX shell
-- rules. latexrun's own gcc-style report on stdout is kept as the raw output tail; the diagnostics
-- still come from the `.log`, so the two never disagree about what a rule matched.
--
-- The `% !TEX program = …` directive names an ENGINE, and latexrun takes one directly through
-- `--latex-cmd` (its default is `pdflatex`), so the directive is one more flag here, as with latexmk.
--
-- Both flags are given in the `key=value` form. latexrun is an argparse program, and argparse resolves
-- `-O=DIR` / `-o=FILE` to the same value as the separated form — verified against argparse itself —
-- which keeps every backend's out-dir option a single `%s` format string in the config.
--
---@module "lvim-tex.build.latexrun"

local config = require("lvim-tex.config")

local fn = vim.fn
local fs = vim.fs

local M = {}

M.name = "latexrun"

-- What the build lifecycle may assume about this backend. latexrun redirects its output wherever it
-- is told, so `out_dir` holds; `clean` is `"all"` because latexrun models exactly ONE clean (see
-- `clean_argv`).
---@type { out_dir: boolean, oneshot: boolean, clean: string }
M.supports = { out_dir = true, oneshot = true, clean = "all" }

--- Is the backend usable on this machine?
---@return boolean ok, string? detail  a health-ready explanation when not
function M.available()
    local bin = config.builders.latexrun.bin
    if not bin or bin == "" then
        return false, "builders.latexrun.bin is empty"
    end
    if fn.executable(bin) ~= 1 then
        return false,
            ("%s is not on PATH — latexrun is a single Python 3 script: put it somewhere on PATH and make it executable"):format(
                bin
            )
    end
    return true, nil
end

--- The output directory to hand latexrun. `nil` means "beside the source", which for a run whose cwd
--- IS the source directory is `.` — never latexrun's own `latex.out` default.
---@param ctx { out_dir: string? }
---@return string
local function object_dir(ctx)
    return ctx.out_dir or "."
end

--- The argv for a BUILD of `ctx.target`.
---@param ctx { target: string, out_dir: string?, engine: string? }
---@return string[]
function M.argv(ctx)
    local spec = config.builders.latexrun
    local argv = { spec.bin }
    -- The engine first, so a user argument in `args` can still override it.
    if ctx.engine and spec.engine_flag then
        argv[#argv + 1] = spec.engine_flag:format(ctx.engine)
    end
    for _, arg in ipairs(spec.args) do
        argv[#argv + 1] = arg
    end
    local out_dir = object_dir(ctx)
    if spec.out_dir_flag then
        argv[#argv + 1] = spec.out_dir_flag:format(out_dir)
    end
    if spec.output_flag then
        -- The same jobname `root.pdf` derives: the compiled TARGET's basename, not the root's.
        argv[#argv + 1] = spec.output_flag:format(out_dir .. "/" .. fn.fnamemodify(ctx.target, ":t:r") .. ".pdf")
    end
    argv[#argv + 1] = ctx.target
    return argv
end

--- The argv for a CLEAN.
---
--- latexrun has exactly one clean action, `--clean-all`, which removes the object directory AND the
--- copied output. It has no aux-only form: everything it generates lives in the object directory and
--- the PDF is a copy out of it, so "the aux files" is not a set latexrun distinguishes. Both
--- `:LvimTex clean` and `:LvimTex clean full` therefore do the same thing here — and it takes the PDF
--- with it. Deleting a hand-picked subset ourselves would be exactly the destructive guess this plugin
--- refuses to make, so the behaviour is documented (README, health) instead of invented.
---@param ctx { target: string, out_dir: string?, full: boolean? }
---@return string[]
function M.clean_argv(ctx)
    local spec = config.builders.latexrun
    local argv = { spec.bin }
    if spec.out_dir_flag then
        argv[#argv + 1] = spec.out_dir_flag:format(object_dir(ctx))
    end
    argv[#argv + 1] = spec.clean_flag or "--clean-all"
    argv[#argv + 1] = ctx.target
    return argv
end

--- The directory the build runs in — the target's own, so relative `\input` paths and
--- `\includegraphics` resolve exactly as they do for a manual run, and a relative object dir means
--- "beside the source".
---@param ctx { target: string }
---@return string
function M.cwd(ctx)
    return fs.dirname(ctx.target)
end

--- Environment additions for the run: the same wide log wrap every backend needs, because latexrun
--- drives an ordinary TeX engine underneath and its log is wrapped by the same rule.
---@return table<string, string>
function M.env()
    return {
        max_print_line = "10000",
        error_line = "254",
        half_error_line = "238",
    }
end

return M
