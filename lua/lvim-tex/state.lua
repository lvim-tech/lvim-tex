-- lvim-tex: RUNTIME state only — never configuration (that lives in lvim-tex.config).
-- Everything here is keyed by the ROOT document's absolute path, because that is the unit a LaTeX
-- project is compiled in: many buffers (chapters, included files) share one root, one build, one log
-- and one diagnostics set. A buffer never owns build state of its own.
--
---@module "lvim-tex.state"

---@class LvimTexBuild
---@field job        vim.SystemObj?  Handle of the running child (nil when idle) — also how it is killed
---@field pid        integer?    Child pid, for reporting
---@field started    integer?    uv.hrtime() at spawn, for the duration readout
---@field finished   integer?    uv.hrtime() at exit
---@field code       integer?    Last exit code
---@field status     "idle"|"building"|"ok"|"failed"
---@field pending    boolean     A rebuild was requested while this one was in flight
---@field output     string[]    Raw stdout+stderr tail of the last build
---@field watchdog   uv.uv_timer_t?  Timer that kills a wedged build
---@field continuous boolean?    The save-driven loop for this root: true/false once the user has
---                             DECIDED, nil while they have not — which is what lets
---                             `continuous.auto_start` be the answer for a project nobody toggled

---@class LvimTexProject
---@field root   string          Absolute path of the root .tex document
---@field target string          Current COMPILE target (root, or a subfile when toggled)
---@field graph  string[]?       Cached include set (absolute paths), nil = not scanned yet
---@field watch  string[]?       Cached rebuild watch set (from the .fls, else the graph)
---@field build  LvimTexBuild
---@field diags  table[]?        Last published diagnostic items (pre-namespace split)
---@field diag_bufs table<integer, boolean>?  Buffers the LAST run published to, so they can be cleared
---@field debounce uv.uv_timer_t?  the continuous loop's pending-rebuild timer for this project
---@field viewer string?         Name of the viewer opened for this project (nil = none opened)
---@field viewer_pdf string?     The PDF that viewer was opened ON — `:LvimTex main` changes which
---                             file the build produces, and the viewer has to follow it

local M = {}

--- Projects by root path.
---@type table<string, LvimTexProject>
M.projects = {}

--- Buffer → root path, so a repeated lookup from the same buffer is free. Invalidated wholesale by
--- `M.reset()` (`:LvimTex reload`) and per-buffer when a magic comment or the file itself changes.
---@type table<integer, string>
M.buf_root = {}

--- The diagnostic namespace, created once on first publish.
---@type integer?
M.ns = nil

--- The project record for `root`, created empty on first touch.
---@param root string  absolute path of the root document
---@return LvimTexProject
function M.project(root)
    local p = M.projects[root]
    if not p then
        p = {
            root = root,
            target = root,
            -- `continuous` is deliberately ABSENT, not false: nil means "undecided", so
            -- `config.continuous.auto_start` supplies the answer until the user toggles it.
            build = { status = "idle", pending = false, output = {} },
        }
        M.projects[root] = p
    end
    return p
end

--- Is a build in flight for `root`?
---@param root string
---@return boolean
function M.building(root)
    local p = M.projects[root]
    return p ~= nil and p.build.job ~= nil
end

--- Every root that currently has a build in flight.
---@return string[]
function M.active_roots()
    local out = {}
    for root, p in pairs(M.projects) do
        if p.build.job then
            out[#out + 1] = root
        end
    end
    table.sort(out)
    return out
end

--- Drop all caches (roots, include graphs, watch sets) but KEEP running builds and their state —
--- `:LvimTex reload` is a "re-read the project" action, not a kill switch.
---@return nil
function M.reset()
    M.buf_root = {}
    for _, p in pairs(M.projects) do
        p.graph = nil
        p.watch = nil
    end
end

return M
