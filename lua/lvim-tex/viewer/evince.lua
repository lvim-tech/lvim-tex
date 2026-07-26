-- lvim-tex: the evince viewer.
--
-- evince has no SyncTeX command line at all: everything but "open this file" happens over its D-Bus
-- session interface. The daemon maps a PDF path to a window bus name (`FindDocument`), and that
-- window then takes a `SyncView` call carrying the source file and line.
--
-- VERIFIED LIVE (2026-07-26, evince 48.4): the daemon activated, `FindDocument` returned the window's
-- bus name, `/org/gnome/evince/Window/0` introspected with both `SyncView` and `SyncSource` on it, and
-- the `SyncView` call this module makes — `(source_file, (line, column), timestamp)` — returned
-- success. So forward search is not guesswork any more.
--
-- INVERSE is still NOT claimed, and that is a capability statement rather than a missing feature: the
-- reverse direction is a `SyncSource` SIGNAL, so receiving it means holding a `gdbus monitor` child
-- for the lifetime of the viewer and routing its output back here. That is a process this plugin does
-- not own yet; claiming `inverse = true` without it would make health lie.
--
---@module "lvim-tex.viewer.evince"

local external = require("lvim-tex.viewer.external")

local fn = vim.fn

local M = {}

M.name = "evince"

---@type { inverse: boolean, reload: "auto"|"push"|"none", status: boolean }
M.supports = { inverse = false, reload = "auto", status = false }

---@type "live"|"docs"|"platform"|"experimental"
M.verified = "live"

--- Is evince installed, and is the D-Bus tooling forward search needs present?
---@return boolean ok, string? detail
function M.available()
    local ok, detail = external.available(M.name)
    if not ok then
        return ok, detail
    end
    if fn.executable("gdbus") ~= 1 then
        return true, "evince is installed, but gdbus is missing — forward search will not work"
    end
    return true, nil
end

--- Open the PDF.
---@param ctx LvimTexViewCtx
---@return boolean ok, string? err
function M.open(ctx)
    local spec = external.spec(M.name)
    local argv = external.extend({ spec.bin }, spec.args)
    argv[#argv + 1] = ctx.pdf
    return external.launch(M.name, ctx.pdf, argv, vim.fs.dirname(ctx.root))
end

--- Is our evince still running?
---@param ctx LvimTexViewCtx
---@return boolean
function M.is_alive(ctx)
    return external.is_alive(M.name, ctx.pdf)
end

--- Forward search over D-Bus: ask the daemon which window owns this document, then tell that window
--- to sync to the source position. Two calls, because the window's bus name is not knowable in
--- advance. Asynchronous throughout — a D-Bus round trip must never block the editor.
---
--- The timestamp argument is passed as 0: evince uses it only for focus-stealing prevention, and 0
--- means "no user interaction triggered this", which is exactly true of a build-driven sync.
---@param ctx LvimTexViewCtx
---@param target { line: integer, col: integer, file: string }
---@return boolean
function M.forward(ctx, target)
    if fn.executable("gdbus") ~= 1 then
        return false
    end
    local uri = "file://" .. ctx.pdf
    vim.system({
        "gdbus",
        "call",
        "--session",
        "--dest",
        "org.gnome.evince.Daemon",
        "--object-path",
        "/org/gnome/evince/Daemon",
        "--method",
        "org.gnome.evince.Daemon.FindDocument",
        uri,
        "false",
    }, { text = true }, function(result)
        local owner = (result.stdout or ""):match("'([^']+)'")
        if not owner then
            return
        end
        vim.system({
            "gdbus",
            "call",
            "--session",
            "--dest",
            owner,
            "--object-path",
            "/org/gnome/evince/Window/0",
            "--method",
            "org.gnome.evince.Window.SyncView",
            target.file,
            ("(%d,%d)"):format(target.line, math.max(1, target.col)),
            "0",
        }, { text = true })
    end)
    return true
end

--- Close our window.
---@param ctx LvimTexViewCtx
---@return nil
function M.close(ctx)
    external.close(M.name, ctx.pdf)
end

return M
