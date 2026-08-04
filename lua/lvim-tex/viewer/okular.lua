-- lvim-tex: the okular viewer.
--
-- okular is SINGLE-INSTANCE by design: `--unique` makes a second invocation address the running
-- window instead of opening another, which is what both opening and forward search rely on here
-- (flags verified against the local binary's `--help`).
--
--   FORWARD   the position travels in the URL fragment: `okular --unique --noraise
--             'file.pdf#src:<line> <texfile>'`. `--noraise` keeps the editor focused — a forward
--             search is "put it there", not "take my attention" — which is what makes okular one of
--             the viewers the cursor-follow may drive (`supports.forward = "quiet"`).
--   INVERSE   `--editor-cmd <string>` sets the callback for THIS document, so no manual step inside
--             okular's settings is needed when we launch it. okular substitutes `%f` (file) and `%l`
--             (line).
--   RELOAD    automatic; okular watches the file.
--
-- LIVENESS IS NOT OUR CHILD PROCESS. That is the whole difficulty of a single-instance viewer, and
-- getting it wrong is silent: when an okular is ALREADY running, the process we spawn hands its URL
-- to that window and exits immediately (measured on this machine: 164 ms). The tracked child is then
-- gone, `external.is_alive` answers false for the rest of the session, and everything gated on it —
-- above all the cursor-follow, which only ever moves a viewer it believes is open — quietly stops
-- working while the window sits there in plain sight.
--
-- okular publishes the answer itself. With `--unique` it owns the well-known session-bus name
-- `org.kde.okular`, whose `/okular` object answers `currentDocument()` with the path on screen. That
-- is the exact question `is_alive` asks, so it is what we ask. The probe is ASYNCHRONOUS — a D-Bus
-- round trip must never sit in the cursor-follow path — and its answer is cached per PDF for
-- `PROBE_TTL`; `open` seeds the cache true so the first forward search after opening does not wait
-- for the bus. Comparing the DOCUMENT (not merely "okular is running") is deliberate: when the user
-- has tabbed away to something else, a follow they never asked for must not drag the tab back.
--
---@module "lvim-tex.viewer.okular"

local external = require("lvim-tex.viewer.external")
local synctex = require("lvim-tex.synctex")

local fn = vim.fn
local uv = vim.uv

local M = {}

M.name = "okular"

---@type { inverse: boolean, reload: "auto"|"push"|"none", status: boolean, forward: "quiet"|"raises"|false, position: boolean }
M.supports = { inverse = true, reload = "auto", status = false, forward = "quiet", position = true }

---@type "live"|"docs"|"platform"|"experimental"
M.verified = "live"

--- ms an answer from the bus is trusted before it is asked again.
local PROBE_TTL = 1500

--- Cached liveness per PDF: is okular on the bus AND showing this file?
---@type table<string, { value: boolean, at: integer, probing: boolean }>
local alive = {}

--- Is okular installed, and is the D-Bus tooling liveness needs present?
---@return boolean ok, string? detail
function M.available()
    local ok, detail = external.available(M.name)
    if not ok then
        return ok, detail
    end
    if fn.executable("gdbus") ~= 1 then
        return true,
            "okular is installed, but gdbus is missing — the cursor-follow cannot tell when its window closes"
    end
    return true, nil
end

--- The argv shared by open and forward search: the binary, `--unique`, the inverse callback, then the
--- user's own arguments.
---@return string[]
local function base()
    local spec = external.spec(M.name)
    local argv = { spec.bin, "--unique" }
    local callback = synctex.editor_command({ file = "%f", line = "%l" })
    if callback then
        argv[#argv + 1] = "--editor-cmd"
        argv[#argv + 1] = callback
    end
    return external.extend(argv, spec.args)
end

--- Ask the session bus which document okular is showing and refresh `alive[pdf]`.
---
--- Fire-and-forget: the caller has already been answered from the cache. A failed call (no okular on
--- the bus at all) is the NEGATIVE answer, not an error — that is what a closed window looks like.
---@param pdf string
---@return nil
local function probe(pdf)
    local entry = alive[pdf]
    if entry and entry.probing then
        return
    end
    alive[pdf] = { value = entry and entry.value or false, at = entry and entry.at or 0, probing = true }
    local ok = pcall(vim.system, {
        "gdbus",
        "call",
        "--session",
        "--dest",
        "org.kde.okular",
        "--object-path",
        "/okular",
        "--method",
        "org.kde.okular.currentDocument",
    }, { text = true }, function(result)
        -- gdbus prints the reply as a tuple literal: ('/path/to/file.pdf',)
        local doc = result.code == 0 and (result.stdout or ""):match("'(.-)'") or nil
        vim.schedule(function()
            alive[pdf] = { value = doc == pdf, at = uv.now(), probing = false }
        end)
    end)
    if not ok then
        alive[pdf] = { value = false, at = uv.now(), probing = false }
    end
end

--- Open the PDF.
---@param ctx LvimTexViewCtx
---@return boolean ok, string? err
function M.open(ctx)
    local argv = base()
    argv[#argv + 1] = ctx.pdf
    local ok, err = external.launch(M.name, ctx.pdf, argv, vim.fs.dirname(ctx.root))
    if ok then
        -- Seed the cache: the window is there whether this invocation became it or handed the file to
        -- the one that was already up, and the bus is not asked before the first follow needs it.
        alive[ctx.pdf] = { value = true, at = uv.now(), probing = false }
    end
    return ok, err
end

--- Is an okular showing this PDF?
---
--- Answered from the cache and refreshed behind it, so this stays free to call on every cursor pause.
--- Without gdbus there is no bus to ask and the tracked child is the only evidence there is — which
--- is right exactly when this process IS the window (nothing else was running when we launched).
---@param ctx LvimTexViewCtx
---@return boolean
function M.is_alive(ctx)
    if fn.executable("gdbus") ~= 1 then
        return external.is_alive(M.name, ctx.pdf)
    end
    local entry = alive[ctx.pdf]
    if not entry or (uv.now() - entry.at) > PROBE_TTL then
        probe(ctx.pdf)
    end
    return (entry and entry.value) == true
end

--- Forward search: the same single-instance invocation with a `#src:` fragment, which okular routes
--- to the window already showing the file.
---@param ctx LvimTexViewCtx
---@param target { line: integer, col: integer, file: string }
---@return boolean
function M.forward(ctx, target)
    local argv = base()
    argv[#argv + 1] = "--noraise"
    argv[#argv + 1] = ("%s#src:%d %s"):format(ctx.pdf, target.line, target.file)
    return external.tell(argv, vim.fs.dirname(ctx.root))
end

--- Which page is the reader on? The same coarse half of the link zathura answers, over the same bus
--- okular already answers `currentDocument()` on — `currentPage()` is 1-BASED here (it is what the
--- page indicator shows), so unlike zathura's property nothing is shifted.
---@param _ LvimTexViewCtx  the view context — part of the viewer interface, unused (the bus is global)
---@param cb fun(page: integer?): nil
---@return nil
function M.position(_, cb)
    if fn.executable("gdbus") ~= 1 then
        return cb(nil)
    end
    local ok = pcall(vim.system, {
        "gdbus",
        "call",
        "--session",
        "--dest",
        "org.kde.okular",
        "--object-path",
        "/okular",
        "--method",
        "org.kde.okular.currentPage",
    }, { text = true }, function(result)
        local n = result.code == 0 and tostring(result.stdout or ""):match("uint32%s+(%d+)") or nil
        vim.schedule(function()
            cb(n and tonumber(n) or nil)
        end)
    end)
    if not ok then
        cb(nil)
    end
end

--- Close our window — and only ours.
---
--- When this project's `open` was DELEGATED to an okular that was already up, that window is the
--- user's, holding whatever else they had open in its other tabs; quitting the shared instance to
--- close one document is not what "close the viewer" means. So the tracked child is killed when it IS
--- the window and nothing is killed when it is not, which is the module's standing rule that a viewer
--- the user opened stays theirs.
---@param ctx LvimTexViewCtx
---@return nil
function M.close(ctx)
    alive[ctx.pdf] = nil
    external.close(M.name, ctx.pdf)
end

return M
