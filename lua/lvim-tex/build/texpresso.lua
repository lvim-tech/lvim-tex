-- lvim-tex: the texpresso backend — and an honest account of what it can and cannot be.
--
-- TeXpresso is not a compiler this plugin can drive like the others. It is an ENGINE AND A VIEWER in
-- one long-lived process: a patched XeTeX that keeps the document resident, re-typesets incrementally
-- as the editor streams changes at it, and paints the result in its own window. Its command line is
--
--     texpresso [-I path]* [-json] [-lines] [-texlive] [-tectonic] [-test-initialize] [-stream] root.tex
--
-- and that is the complete list — there is no `--output`, no `--batch`, no flag that makes it write a
-- PDF. It never exits on its own; the session ends when the user closes the window. Which means:
--
--   • It CANNOT be a one-shot build. Handing this argv to the batch lifecycle would spawn a window,
--     produce no `.log` to parse, no PDF for the viewer layer to show, and then be killed by the
--     watchdog after `continuous.timeout` and reported as a failed build. That is why the module
--     declares `supports.oneshot = false`: the lifecycle must REFUSE it with a sentence the user can
--     act on, not run it and call the result a build.
--   • Its live mode bypasses our viewer layer BY DESIGN (the plan's C13 says so). The page is
--     texpresso's own window; lvim-preview, the reload push, the error strip and the SyncTeX bridge
--     all belong to a PDF we would no longer be producing.
--
-- WHAT A LIVE MODE WOULD TAKE (not shipped — nothing here pretends it works):
--   1. A SESSION owner, not a build backend: one long-lived `vim.system` per project with `stdin`
--      kept open, started with `-json` (or the s-expression default) and the distribution flag
--      (`-texlive` / `-tectonic`, matching how the document's packages are found).
--   2. An outbound protocol writer on that stdin. TeXpresso's editor protocol is message-per-line:
--      `open`/`change`/`close` mirror the buffer's contents as it is edited (so a `TextChanged`
--      autocmd, not a save), `synctex-forward` moves its page to a source position, `theme` hands it
--      our palette, plus its page-motion messages.
--   3. An inbound reader for the same channel: its diagnostics and its inverse-search positions arrive
--      as messages, NOT as a `.log` file — so the log parser and `lvim-tex.synctex` are both bypassed,
--      and the diagnostics would have to be published from the protocol instead.
--   4. A decision, which is a product question and not ours to make silently: while a texpresso session
--      owns the document there is no PDF, so `:LvimTex view`, forward search and the preview page have
--      nothing to act on. Either the project keeps a normal builder alongside for artefacts, or those
--      commands must report that the session owns the rendering.
--
-- What IS shipped: the exact argv of a session (so the wiring above has one place to get it right),
-- availability, and `check_argv` — `-test-initialize` is texpresso's only finite invocation: it runs a
-- single compilation cycle and exits, which makes it a real probe that the binary can find its TeX
-- distribution. It writes nothing, so it is a health check, not a build.
--
---@module "lvim-tex.build.texpresso"

local config = require("lvim-tex.config")

local fn = vim.fn
local fs = vim.fs

local M = {}

M.name = "texpresso"

-- What the build lifecycle may assume. `oneshot = false` is the load-bearing one — see the header.
---@type { out_dir: boolean, oneshot: boolean, clean: boolean, artifact: boolean }
M.supports = { out_dir = false, oneshot = false, clean = false, artifact = false }

-- How `builders.texpresso.distribution` maps to the flag that tells texpresso where to find packages.
-- `auto` passes nothing, which is texpresso's own default probe.
---@type table<string, string>
local DISTRIBUTION_FLAG = { texlive = "-texlive", tectonic = "-tectonic" }

--- Is the backend usable on this machine?
---@return boolean ok, string? detail
function M.available()
    local bin = config.builders.texpresso.bin
    if not bin or bin == "" then
        return false, "builders.texpresso.bin is empty"
    end
    if fn.executable(bin) ~= 1 then
        return false, ("%s is not on PATH — texpresso is built from source (it ships no binary release)"):format(bin)
    end
    return true, nil
end

--- The argv of a texpresso SESSION for `ctx.target`: the distribution flag, every configured include
--- path, the user's own arguments, then the document.
---
--- `ctx.out_dir` and `ctx.engine` are accepted and ignored: texpresso writes no artefacts and is its
--- own engine.
---
--- This is `argv` — the module's real command line — and it is deliberately NOT a batch build. The
--- lifecycle asks `supports.oneshot` before spawning anything, so this argv reaches a process only
--- through a session owner (which this version does not ship; see the header).
---@param ctx { target: string, out_dir: string?, engine: string? }
---@return string[]
function M.argv(ctx)
    local spec = config.builders.texpresso
    local argv = { spec.bin }
    local dist = DISTRIBUTION_FLAG[spec.distribution or "auto"]
    if dist then
        argv[#argv + 1] = dist
    end
    for _, path in ipairs(spec.include_paths or {}) do
        argv[#argv + 1] = "-I"
        argv[#argv + 1] = path
    end
    for _, arg in ipairs(spec.args) do
        argv[#argv + 1] = arg
    end
    argv[#argv + 1] = ctx.target
    return argv
end

--- The argv of texpresso's ONLY finite invocation: `-test-initialize` runs one compilation cycle and
--- exits, so its exit code answers "can this binary actually typeset this document on this machine".
--- Health uses it; it produces no PDF and no log, so nothing else can.
---@param ctx { target: string, out_dir: string?, engine: string? }
---@return string[]
function M.check_argv(ctx)
    local argv = M.argv(ctx)
    -- Before the document, which must stay last.
    table.insert(argv, #argv, "-test-initialize")
    return argv
end

--- The directory a session runs in — the target's own, so relative `\input` and graphics resolve as
--- they do for every other backend.
---@param ctx { target: string }
---@return string
function M.cwd(ctx)
    return fs.dirname(ctx.target)
end

--- Environment additions. The wide log wrap is kept for symmetry with the other backends and costs
--- nothing: texpresso reports through its protocol, not through a wrapped log file.
---@return table<string, string>
function M.env()
    return {
        max_print_line = "10000",
        error_line = "254",
        half_error_line = "238",
    }
end

return M
