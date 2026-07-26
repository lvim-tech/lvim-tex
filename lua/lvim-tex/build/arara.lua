-- lvim-tex: the arara backend.
--
-- arara inverts where the build recipe lives. latexmk and latexrun decide the workflow from the
-- document's dependencies; arara does what the DOCUMENT tells it to, through directives in its own
-- header:
--
--     % arara: pdflatex: { interaction: nonstopmode, synctex: yes }
--     % arara: biber
--     % arara: pdflatex
--
-- That is why this backend takes almost no arguments: the engine, the number of runs, the bibliography
-- tool and the shell-escape decision are all the document's, not ours. Three consequences, each a
-- deliberate limit rather than something to work around:
--
--   • The `% !TEX program = …` ENGINE directive is IGNORED. arara's own directives choose the tool,
--     and there is no flag that overrides them; honouring the other directive would mean editing the
--     user's document. Health reports the conflict instead.
--   • There is NO output directory. arara has no `-output-directory` equivalent — the tools its rules
--     invoke run in the working directory and write beside the source. So this backend declares
--     `supports.out_dir = false`, and the ONE answer for where artefacts live (`root.out_dir`) must
--     resolve to the source directory while arara is the builder, or the log parser, the PDF path and
--     forward search all point into an empty `build/`.
--   • There is no CLEAN. arara ships no clean action of its own (a document can declare a `clean`
--     rule, which is again the document's business), so `clean_argv` is absent and `:LvimTex clean`
--     says so rather than deleting files nobody asked it to.
--
-- A document with no directives is not a failure of the plugin: arara reports that it found none and
-- exits non-zero, which is the honest answer and exactly what health tells the user to look for.
--
-- The working directory is set the way every other backend sets it — through the spawn's own `cwd`,
-- not arara's `-d/--working-directory`. One mechanism for one thing: the build lifecycle already runs
-- every backend in the target's directory, and a second, backend-specific way to say the same would be
-- one more thing that can disagree.
--
---@module "lvim-tex.build.arara"

local config = require("lvim-tex.config")

local fn = vim.fn
local fs = vim.fs

local M = {}

M.name = "arara"

-- What the build lifecycle may assume. `out_dir = false` is the load-bearing one: arara cannot
-- redirect its output, so the artefact directory for an arara project is the source directory.
---@type { out_dir: boolean, oneshot: boolean, clean: boolean }
M.supports = { out_dir = false, oneshot = true, clean = false }

--- Is the backend usable on this machine?
---@return boolean ok, string? detail
function M.available()
    local bin = config.builders.arara.bin
    if not bin or bin == "" then
        return false, "builders.arara.bin is empty"
    end
    if fn.executable(bin) ~= 1 then
        return false, ("%s is not on PATH — arara ships with TeX Live/MiKTeX and needs a Java runtime"):format(bin)
    end
    return true, nil
end

--- The argv for a BUILD of `ctx.target`.
---
--- `ctx.out_dir` and `ctx.engine` are accepted and IGNORED — arara supports neither (see the header).
--- The target is passed as a plain path: arara resolves it against the working directory, which is the
--- directory it is spawned in.
---@param ctx { target: string, out_dir: string?, engine: string? }
---@return string[]
function M.argv(ctx)
    local spec = config.builders.arara
    local argv = { spec.bin }
    for _, arg in ipairs(spec.args) do
        argv[#argv + 1] = arg
    end
    argv[#argv + 1] = ctx.target
    return argv
end

--- The directory the build runs in — the target's own, which is also where arara's rules will write.
---@param ctx { target: string }
---@return string
function M.cwd(ctx)
    return fs.dirname(ctx.target)
end

--- Environment additions: the wide log wrap. arara invokes an ordinary engine, so the engine's log is
--- wrapped by the same rule and the parser depends on it being raised.
---@return table<string, string>
function M.env()
    return {
        max_print_line = "10000",
        error_line = "254",
        half_error_line = "238",
    }
end

return M
