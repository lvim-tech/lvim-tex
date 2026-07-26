-- lvim-tex: the VIEWER LAYER — one interface, many implementations, and the core never knows which
-- one it is driving.
--
-- A PDF viewer differs from every other part of this plugin in that it is not ours: it is a browser
-- page, a separate process, or a DBus service, each with its own idea of what "reload" and "go to this
-- position" mean. Modelling those differences at every call site would spread viewer knowledge through
-- the build lifecycle, so they are declared ONCE, as data, on each module's `supports` table, and the
-- lifecycle asks that table rather than the module's name:
--
--   reload = "auto"   the viewer notices the file changed by itself — we do nothing
--   reload = "push"   we must tell it (our own preview page, on its websocket)
--   reload = "none"   it cannot reload at all; the user re-opens it (health says so)
--   status            it can show OUR state (building / failed) over the last good render
--   inverse           a click in it can reach the editor (phase 4)
--
-- SELECTION. `viewer.name = "auto"` walks `viewer.priority` (a per-OS default list, overridable) and
-- takes the first module that is BOTH implemented in this version and available on this machine. A
-- name in the list with no module yet is skipped rather than erroring — the priority lists name every
-- viewer the plan covers, so a user's config keeps meaning as the later modules land, and health
-- reports which state each name is in.
--
-- KEYED BY PROJECT, not by module. The plan's sketch passed a lone `pdf` string; that cannot express
-- two documents open at once, which is the normal case for a paper and its beamer slides. Every entry
-- point takes a context (`root`, `target`, `pdf`) and each module keys its own per-project bookkeeping
-- on it (see findings `G10`).
--
---@module "lvim-tex.viewer"

local config = require("lvim-tex.config")
local root_mod = require("lvim-tex.root")
local state = require("lvim-tex.state")

local M = {}

--- What every viewer entry point receives: the project, what is being compiled, and the file to show.
---@class LvimTexViewCtx
---@field root   string  absolute path of the root document — the project identity
---@field target string  the file actually compiled (root, or a subfile when toggled)
---@field pdf    string  absolute path of the produced PDF

--- The interface a viewer module implements. Only `name`, `available`, `supports`, `open`, `is_alive`
--- and `close` are mandatory; the rest are asked for through `supports` and may be absent.
---@class LvimTexViewer
---@field name      string
---@field available fun(): boolean, string?           probe + the health sentence when unavailable
---@field supports  { inverse: boolean, reload: "auto"|"push"|"none", status: boolean }
---@field open      fun(ctx: LvimTexViewCtx): boolean, string?
---@field is_alive  fun(ctx: LvimTexViewCtx): boolean
---@field close     fun(ctx: LvimTexViewCtx)
---@field reload    fun(ctx: LvimTexViewCtx)?         only when supports.reload == "push"
---@field status    fun(ctx: LvimTexViewCtx, st: "building"|"ok"|"error", message: string?)?
---@field forward   fun(ctx: LvimTexViewCtx, target: table): boolean?
---@field verified  ("live"|"docs"|"platform"|"experimental")?  how far it has been PROVEN (health)
---@field inverse_setup fun(): { command: string, arguments: string }  only for a viewer whose inverse
---                     search is a MANUAL step inside its own preferences (Skim); health prints it

--- Every viewer this plugin plans to drive, in the order health reports them. A name maps to its
--- module path; `false` marks one whose module has not landed yet, which is what lets the default
--- priority lists stay complete while the phases roll in.
---@type table<string, string|false>
local MODULES = {
    preview = "lvim-tex.viewer.preview",
    zathura = "lvim-tex.viewer.zathura",
    sioyek = "lvim-tex.viewer.sioyek",
    okular = "lvim-tex.viewer.okular",
    evince = "lvim-tex.viewer.evince",
    skim = "lvim-tex.viewer.skim",
    sumatra = "lvim-tex.viewer.sumatra",
}

--- Priority per platform when `viewer.name = "auto"` and the user set no list of their own. Our own
--- preview page leads everywhere: it needs no install, works on every platform, and is the only
--- viewer that can show a build state.
---@type table<string, string[]>
local DEFAULT_PRIORITY = {
    linux = { "preview", "zathura", "sioyek", "okular", "evince" },
    mac = { "preview", "skim" },
    windows = { "preview", "sumatra" },
}

--- Loaded modules, so a probe is not a fresh `require` every time.
---@type table<string, LvimTexViewer|false>
local loaded = {}

--- This machine's key into `DEFAULT_PRIORITY`.
---@return string
local function platform()
    if vim.fn.has("mac") == 1 then
        return "mac"
    end
    if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
        return "windows"
    end
    return "linux"
end

--- The module for `name`, or nil when it is not implemented in this version (or failed to load).
---@param name string
---@return LvimTexViewer?
function M.module(name)
    local cached = loaded[name]
    if cached ~= nil then
        return cached or nil
    end
    local path = MODULES[name]
    if not path then
        loaded[name] = false
        return nil
    end
    local ok, mod = pcall(require, path)
    loaded[name] = (ok and type(mod) == "table") and mod or false
    return loaded[name] or nil
end

--- The names to try, in order: the user's `viewer.priority`, else this platform's default list.
---@return string[]
function M.priority()
    local list = config.viewer.priority
    if type(list) == "table" and #list > 0 then
        return list
    end
    return DEFAULT_PRIORITY[platform()] or DEFAULT_PRIORITY.linux
end

--- The viewer to drive: the one named by `viewer.name`, or the first available of the priority list.
---
--- A name that IS configured is never silently replaced — if the user asked for zathura and zathura is
--- not there, that is an error worth seeing, not a reason to open a browser instead.
---@return LvimTexViewer? viewer, string? err
function M.resolve()
    local name = config.viewer.name
    if name and name ~= "auto" then
        local mod = M.module(name)
        if not mod then
            return nil, ("viewer %q is not available in this version"):format(name)
        end
        local ok, why = mod.available()
        if not ok then
            return nil, ("viewer %q is unusable: %s"):format(name, why or "not found")
        end
        return mod, nil
    end
    for _, candidate in ipairs(M.priority()) do
        local mod = M.module(candidate)
        if mod and mod.available() then
            return mod, nil
        end
    end
    return nil, "no viewer available (install one, or set viewer.name)"
end

--- The context for `root`, or nil when the buffer belongs to no project.
---@param root string
---@return LvimTexViewCtx
local function context(root)
    local project = state.project(root)
    return { root = root, target = project.target, pdf = root_mod.pdf(root, project.target) }
end

--- Ask a viewer for something it may not implement. Keeps the lifecycle free of `if mod.status then`.
---@param mod LvimTexViewer
---@param method string
---@param ... any
---@return any
local function call(mod, method, ...)
    local fn = mod[method]
    if type(fn) ~= "function" then
        return nil
    end
    return fn(...)
end

--- Open (or focus) the viewer on this project's PDF.
---@param root string
---@return boolean ok, string? err
function M.open(root)
    local mod, err = M.resolve()
    if not mod then
        return false, err
    end
    local ctx = context(root)
    local ok, why = mod.open(ctx)
    if ok then
        state.project(root).viewer = mod.name
    end
    return ok, why
end

--- Close this project's viewer (no-op when it was never opened).
---@param root string
---@return nil
function M.close(root)
    local name = state.project(root).viewer
    local mod = name and M.module(name) or nil
    if mod then
        mod.close(context(root))
    end
    state.project(root).viewer = nil
end

--- Is a viewer currently showing this project?
---@param root string
---@return boolean
function M.is_alive(root)
    local name = state.project(root).viewer
    local mod = name and M.module(name) or nil
    return (mod and mod.is_alive(context(root))) == true
end

--- A build for `root` just started.
---
--- Two things can happen, and which is which is `supports.status`: a viewer that can render OUR state
--- is opened right away and shows "building" over whatever it last rendered — that is the whole point
--- of registering the artifact before the first build. A viewer that cannot (every external one) is
--- left alone until there is a PDF worth opening; `M.on_build_done` opens it then.
---@param root string
---@return nil
function M.on_build_start(root)
    if not config.viewer.enabled then
        return
    end
    local mod = M.resolve()
    if not mod then
        return
    end
    local ctx = context(root)
    if not mod.is_alive(ctx) then
        if not (config.viewer.open_on_start and mod.supports.status) then
            return
        end
        if not mod.open(ctx) then
            return
        end
        state.project(root).viewer = mod.name
    end
    call(mod, "status", ctx, "building")
end

--- A build for `root` finished.
---
--- On success the viewer is told to refetch — unless it watches the file itself (`reload = "auto"`),
--- in which case pushing would be a second, racing reload of the same write. On failure nothing is
--- refetched at all: the last good render stays on screen under an error strip, because a PDF from a
--- failed run is either stale or half-written and swapping it in loses the user's page.
---@param root string
---@param ok boolean  the build exited 0
---@param message string?  a short failure summary for the viewer's strip
---@return nil
function M.on_build_done(root, ok, message)
    if not config.viewer.enabled then
        return
    end
    local mod = M.resolve()
    if not mod then
        return
    end
    local ctx = context(root)
    if not mod.is_alive(ctx) then
        -- Nothing is showing. Open now if the user asked for it and there is something to show.
        if not (ok and config.viewer.open_on_start) then
            return
        end
        if vim.fn.filereadable(ctx.pdf) ~= 1 or not mod.open(ctx) then
            return
        end
        state.project(root).viewer = mod.name
        return
    end
    if ok then
        if mod.supports.reload == "push" then
            call(mod, "reload", ctx)
        end
        call(mod, "status", ctx, "ok")
    else
        call(mod, "status", ctx, "error", message)
    end
end

--- Forward search: put the viewer at the position that corresponds to `file:line:col`.
---
--- The SyncTeX resolution happens HERE, once, and only for viewers that need a PDF coordinate. A
--- viewer with its own SyncTeX support takes the SOURCE position instead (that is what its
--- `--synctex-forward` / `#src:` flags are for) and resolves it itself — asking `synctex` on their
--- behalf would be a second, redundant resolution that can only disagree with theirs.
---@param root string
---@param file string   absolute path of the source file
---@param lnum integer
---@param col integer
---@param done fun(ok: boolean, err: string?): nil
---@return nil
function M.forward(root, file, lnum, col, done)
    local mod, err = M.resolve()
    if not mod then
        return done(false, err)
    end
    if type(mod.forward) ~= "function" then
        return done(false, ("%s cannot forward-search"):format(mod.name))
    end
    local ctx = context(root)
    local source = { file = file, line = lnum, col = col }
    if mod.supports.status then
        -- Our own page: it knows nothing about TeX, so it needs the PDF coordinate.
        local synctex = require("lvim-tex.synctex")
        return synctex.view(root, file, lnum, col, function(target, why)
            if not target then
                return done(false, why)
            end
            done(mod.forward(ctx, vim.tbl_extend("keep", target, source)) ~= false, nil)
        end)
    end
    done(mod.forward(ctx, source) ~= false, nil)
end

--- Every viewer name with its state on THIS machine — what health prints and `:LvimTex info` reports.
---@return { name: string, implemented: boolean, available: boolean, detail: string?, reload: string?, inverse: boolean?, verified: string? }[]
function M.matrix()
    local out = {}
    for _, name in ipairs({ "preview", "zathura", "sioyek", "okular", "evince", "skim", "sumatra" }) do
        local mod = M.module(name)
        if not mod then
            out[#out + 1] = { name = name, implemented = false, available = false }
        else
            local ok, detail = mod.available()
            out[#out + 1] = {
                name = name,
                implemented = true,
                available = ok,
                detail = detail,
                reload = mod.supports.reload,
                inverse = mod.supports.inverse,
                verified = mod.verified or "live",
            }
        end
    end
    return out
end

return M
