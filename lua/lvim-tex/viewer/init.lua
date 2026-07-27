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
--   forward = "quiet"   it can be moved to a position WITHOUT taking the keyboard focus
--   forward = "raises"  moving it always presents its window — the editor loses the focus
--   forward = false     it cannot be moved at all
--   position            it can be ASKED where its reader is (page granularity)
--
-- WHY "quiet" IS ITS OWN FACT. A forward search comes from two places that want opposite things. The
-- EXPLICIT one (`,lv`) is a request: raising the window is part of "show me this". The AUTOMATIC one —
-- the cursor-follow — was never asked for, and a viewer that presents its window on every sync makes
-- the editor unusable: the focus leaves the buffer a fraction of a second after the cursor settles,
-- with nothing on screen to explain why. Whether a viewer can sync quietly is a fact about the viewer
-- (okular has `--noraise`, sioyek `--nofocus`, Skim's displayline `-g`; evince's `SyncView` and
-- Sumatra's `-forward-search` present unconditionally), so it is declared here with the rest of them
-- and `M.follow` — not `M.forward` — is the entry point that respects it.
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
---@field supports  { inverse: boolean, reload: "auto"|"push"|"none", status: boolean, forward: "quiet"|"raises"|false, position: boolean? }
---@field open      fun(ctx: LvimTexViewCtx): boolean, string?
---@field is_alive  fun(ctx: LvimTexViewCtx): boolean
---@field close     fun(ctx: LvimTexViewCtx)
---@field reload    fun(ctx: LvimTexViewCtx)?         only when supports.reload == "push"
---@field status    fun(ctx: LvimTexViewCtx, st: "building"|"ok"|"error", message: string?)?
---@field forward   fun(ctx: LvimTexViewCtx, target: table): boolean?
---@field position  fun(ctx: LvimTexViewCtx, cb: fun(page: integer?)): nil?  only when
---                 `supports.position` — answers WHICH PAGE the reader is on, 1-based
---@field retarget  fun(ctx: LvimTexViewCtx, old_pdf: string)?  show a DIFFERENT file without losing
---                 the window/tab; the layer falls back to close-then-open when a module has none
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

--- Record WHAT was opened and ON WHICH file. Three call sites open a viewer (the command, and the two
--- build-lifecycle hooks) and `retarget` needs the file from all of them — a viewer opened by a build
--- and then retargeted was the bug this exists to prevent.
---@param root string
---@param mod LvimTexViewer
---@param ctx LvimTexViewCtx
---@return nil
local function remember(root, mod, ctx)
    local project = state.project(root)
    project.viewer = mod.name
    project.viewer_pdf = ctx.pdf
    -- A viewer that can be asked where its reader is starts being asked the moment it is ours.
    M.follow_viewer(root)
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
        remember(root, mod, ctx)
    end
    return ok, why
end

--- Show this project's PDF if it is not already on screen — the "there is something to look at now"
--- entry point, as opposed to `M.open`, which is an explicit request and always acts.
---
--- Three conditions, all of them the user's own settings rather than a guess: the viewer layer is on,
--- `viewer.open_on_start` says a viewer may be opened without being asked for, and the file EXISTS
--- (opening a viewer on a PDF that is not there is how you get an error dialog instead of a document).
--- Already-open stays open, so this can be called freely.
---@param root string
---@return boolean opened
function M.show(root)
    if not config.viewer.enabled or config.viewer.open_on_start ~= true then
        return false
    end
    if M.is_alive(root) then
        return false
    end
    local project = state.project(root)
    if vim.fn.filereadable(root_mod.pdf(root, project.target)) ~= 1 then
        return false
    end
    return M.open(root) == true
end

--- The compile target changed (`:LvimTex main`), so the build now writes a DIFFERENT PDF — point the
--- open viewer at it.
---
--- Without this, toggling to a subfile builds `ch1.pdf` while the page keeps serving `main.pdf`: the
--- viewer looks alive and shows something plausible, which is worse than showing nothing. Our own page
--- can be re-pointed in place (its URL is keyed on the project id, not the path, so the open tab stays
--- valid); a viewer with no `retarget` is closed on the old file and opened on the new one.
---@param root string
---@return nil
function M.retarget(root)
    local project = state.project(root)
    local mod = project.viewer and M.module(project.viewer) or nil
    if not mod or not project.viewer_pdf then
        return
    end
    local ctx = context(root)
    if project.viewer_pdf == ctx.pdf then
        return
    end
    -- The link belonged to the OLD file: its ownership and last exchanged line say nothing about the
    -- document about to be shown, and keeping them would suppress the first follow into it.
    require("lvim-tex.synctex").reset(project.viewer_pdf)
    if type(mod.retarget) == "function" then
        mod.retarget(ctx, project.viewer_pdf)
    else
        mod.close({ root = root, target = project.target, pdf = project.viewer_pdf })
        mod.open(ctx)
    end
    project.viewer_pdf = ctx.pdf
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
    M.unfollow_viewer(root)
    state.project(root).viewer = nil
    state.project(root).viewer_pdf = nil
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
        remember(root, mod, ctx)
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
        remember(root, mod, ctx)
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

--- The viewer a sync should DRIVE: the one actually open for this project, falling back to the
--- configured choice when none was ever opened.
---
--- `M.resolve()` answers "which viewer would we open", and that is the right question when opening.
--- It is the WRONG one for moving a window that already exists: the two diverge as soon as
--- `viewer.name` is edited mid-session, or as `auto` resolution changes with availability, and then
--- a follow probes a viewer that is not open (silently doing nothing) or moves a different window
--- than the one the user is reading. `state.project(root).viewer` is what `is_alive` / `close` /
--- `retarget` already key off, so this makes the moving entry points agree with them.
---@param root string
---@return LvimTexViewer? viewer, string? err
local function driving(root)
    local name = state.project(root).viewer
    local mod = name and M.module(name) or nil
    if mod then
        return mod, nil
    end
    return M.resolve()
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
---@param done fun(ok: boolean, err: string?): nil?  optional; normalised to a no-op
---@return nil
function M.forward(root, file, lnum, col, done)
    -- Normalised once: every early return reports through it, and a public entry point whose error
    -- path calls a nil value is a trap that only ever springs when something has already gone wrong.
    done = done or function() end
    local mod, err = driving(root)
    if not mod then
        return done(false, err)
    end
    if type(mod.forward) ~= "function" then
        return done(false, ("%s cannot forward-search"):format(mod.name))
    end
    local ctx = context(root)
    local source = { file = file, line = lnum, col = col }
    if mod.supports.status then
        -- Our own page: it knows nothing about TeX, so it needs the PDF coordinate — and resolving
        -- one spawns a `synctex` child. The debounce upstream stops a second TIMER, not a second
        -- CHILD: a later pause can start one while the first is still running, and if the first
        -- finishes last the page is moved back to where the cursor used to be. The same ticket the
        -- reverse direction uses settles it — the newest request is the only one allowed to land.
        local synctex = require("lvim-tex.synctex")
        local ticket = synctex.link_ticket(ctx.pdf)
        return synctex.view(root, file, lnum, col, function(target, why)
            if not synctex.link_current(ctx.pdf, ticket) then
                return done(false, nil)
            end
            if not target then
                return done(false, why)
            end
            done(mod.forward(ctx, vim.tbl_extend("keep", target, source)) ~= false, nil)
        end)
    end
    done(mod.forward(ctx, source) ~= false, nil)
end

--- The forward capability IN EFFECT for a viewer: what its module declares, unless the user's viewer
--- spec says otherwise.
---
--- The override exists because one of these facts is not ours to know. zathura raises its window on
--- every D-Bus command unless its own `dbus-raise-window` is off — a per-instance setting, not a
--- property of the binary — so `viewer.zathura.forward = "quiet"` is how the user says "I want that
--- trade", and the module then arranges it on the instance it launches. Declared per viewer spec
--- rather than as a zathura special case: any viewer whose quietness turns on its own configuration
--- can be told the same way.
---@param mod LvimTexViewer
---@return "quiet"|"raises"|false|nil
local function forward_mode(mod)
    local spec = config.viewer[mod.name]
    if type(spec) == "table" and spec.forward ~= nil then
        return spec.forward
    end
    return mod.supports.forward
end

--- The AUTOMATIC forward search — the cursor-follow, and nothing else.
---
--- It differs from `M.forward` in the two ways an unasked-for action must differ from a requested
--- one, and both belong here rather than at the call site, which knows nothing about viewers:
---
---   • it never OPENS a viewer. Only a viewer already showing this project is moved; for a
---     single-instance viewer that is a question about the WINDOW, not about a child process (see
---     `okular.is_alive`).
---   • it never STEALS THE FOCUS. A viewer whose sync presents its window (`forward = "raises"`) is
---     left alone — being pulled out of the buffer every time the cursor settles is worse than not
---     following at all. The explicit `,lv` still drives it, because there the raise is the point.
---
--- Silent by design: it reports nothing, since the user did not ask for anything.
---@param root string
---@param file string   absolute path of the source file
---@param lnum integer
---@param col integer
---@return nil
function M.follow(root, file, lnum, col)
    local mod = driving(root)
    if not mod or forward_mode(mod) ~= "quiet" then
        return
    end
    -- Through the PUBLIC seam, not `mod.is_alive` directly: `M.is_alive` asks about the viewer this
    -- project actually OPENED (`state.project(root).viewer`), which is precisely the question a
    -- follow must ask — it may never open one. Reaching past it also bypassed the layer's own
    -- bookkeeping, and with it the only seam a test can stub.
    if not M.is_alive(root) then
        return
    end
    -- The viewer moved US moments ago (a page the reader scrolled, whose position we followed): this
    -- CursorMoved is the echo of that, and answering it with a forward search is the loop the
    -- ownership window exists to break. Every question is asked of THIS project's link — a second
    -- document's preview must not be able to silence this one's follow.
    local synctex = require("lvim-tex.synctex")
    local ctx = context(root)
    if synctex.link_locked_out(ctx.pdf, "editor") then
        return
    end
    -- …and, independently of the timing, never answer with the line the link last exchanged: the
    -- placement the page asked for raises a scroll event whose debounced echo outlives the ownership
    -- window, and answering it is what makes the two sides tug at each other.
    if synctex.link_repeats(ctx.pdf, lnum) then
        return
    end
    synctex.claim_link(ctx.pdf, "editor")
    -- The line is recorded only once the search has actually been DELIVERED. Marking it up front
    -- makes a forward search that failed — a stale PDF, a file absent from the SyncTeX data, a
    -- viewer command that did not run — indistinguishable from one that worked, and then suppresses
    -- for ever the retry that would have fixed it.
    M.forward(root, file, lnum, col, function(ok)
        if ok then
            synctex.link_mark(ctx.pdf, lnum)
            M.resync_page(root, mod, ctx)
        end
    end)
end

-- ── the page poll: the coarse half of the two-way link ──────────────────────
--
-- Only our own preview page can report a POSITION; an external viewer at best publishes which PAGE
-- it is showing, and none of them announces a change — zathura's whole interface carries one signal
-- and it is for ctrl-click. So "the editor follows the viewer" for an external viewer is a poll, and
-- the timer belongs here rather than in synctex: whether a viewer can be asked at all is a fact
-- about viewers, and this layer is where those live.
--
-- One timer per project, released through the same stop → is_closing → close discipline as every
-- other handle in this plugin.

---@type table<string, uv.uv_timer_t>  root → its page-poll timer
local polls = {}

--- Stop and release the poll for `root` (all of them when `root` is nil).
---@param root string?
---@return nil
local function stop_poll(root)
    for key, timer in pairs(polls) do
        if root == nil or key == root then
            timer:stop()
            if not timer:is_closing() then
                timer:close()
            end
            polls[key] = nil
        end
    end
end

--- Start (or restart) the page poll for `root`, if everything it needs is true.
---
--- Deliberately silent about every reason not to run: this is a background capability, and a user who
--- has not turned it on, or whose viewer cannot answer, must not be told about it on a timer.
---@param root string
---@return nil
local function start_poll(root)
    stop_poll(root)
    local synctex = require("lvim-tex.synctex")
    local back = config.synctex.follow_back or {}
    local poll = back.poll or {}
    if not (back.enabled and poll.enabled and config.synctex.inverse) then
        return
    end
    local mod = driving(root)
    if not mod or mod.supports.position ~= true or type(mod.position) ~= "function" then
        return
    end
    local timer = vim.uv.new_timer()
    if not timer then
        return
    end
    polls[root] = timer
    local interval = math.max(100, tonumber(poll.interval) or 1000)
    timer:start(
        interval,
        interval,
        vim.schedule_wrap(function()
            local ctx = context(root)
            -- Nothing to ask, or the editor moved things moments ago and this read would only see
            -- our own forward search arriving.
            if not mod.is_alive(ctx) or synctex.link_locked_out(ctx.pdf, "viewer") then
                return
            end
            mod.position(ctx, function(page)
                if page then
                    synctex.follow_back_page(ctx.pdf, page)
                end
            end)
        end)
    )
end

--- After the editor moved a PAGE-ONLY viewer, learn which page it landed on.
---
--- zathura resolves `--synctex-forward` itself, so at send time we do not know the answer — and the
--- page poll would read it back a moment later as if the READER had turned there and dutifully move
--- the source to it. Reading the page once after the move and recording it as exchanged is a
--- self-syncing baseline: value equality then kills the echo whatever phase the poll is in.
---@param root string
---@param mod LvimTexViewer
---@param ctx LvimTexViewCtx
---@return nil
function M.resync_page(root, mod, ctx)
    if mod.supports.position ~= true or type(mod.position) ~= "function" then
        return
    end
    if not polls[root] then
        return
    end
    vim.defer_fn(function()
        mod.position(ctx, function(page)
            if page then
                require("lvim-tex.synctex").link_mark_page(ctx.pdf, page)
            end
        end)
    end, 300)
end

--- Begin following this project's viewer, when it is one that can be asked where its reader is.
--- Idempotent; a call with the feature off simply stops any poll that was running.
---@param root string
---@return nil
function M.follow_viewer(root)
    start_poll(root)
end

--- Stop following (a project's viewer, or every one).
---@param root string?
---@return nil
function M.unfollow_viewer(root)
    stop_poll(root)
end

--- Ask the viewer showing this project which page its reader is on.
---
--- `nil` when nothing is open, when the viewer cannot be asked, or when the answer does not arrive —
--- the caller decides whether that is worth a message, because the same question is asked by a
--- silent poll and by an explicit command.
---@param root string
---@param cb fun(page: integer?, mod: LvimTexViewer?): nil
---@return nil
function M.position(root, cb)
    local mod = driving(root)
    if not mod or mod.supports.position ~= true or type(mod.position) ~= "function" then
        return cb(nil, mod)
    end
    local ctx = context(root)
    if not mod.is_alive(ctx) then
        return cb(nil, mod)
    end
    mod.position(ctx, function(page)
        cb(page, mod)
    end)
end

--- Every viewer name with its state on THIS machine — what health prints and `:LvimTex info` reports.
---@return { name: string, implemented: boolean, available: boolean, detail: string?, reload: string?, inverse: boolean?, forward: string|false|nil, verified: string? }[]
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
                forward = forward_mode(mod),
                verified = mod.verified or "live",
            }
        end
    end
    return out
end

return M
