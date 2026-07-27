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

--- `forward = "raises"`: `SyncView` ends in `gtk_window_present_with_time`, so every sync brings the
--- evince window forward and the editor loses the keyboard focus. There is no quiet variant of the
--- call — the D-Bus interface offers exactly one way to move the view — so this is a fact about
--- evince, not a setting. The consequence is that the cursor-follow leaves evince alone (it would
--- otherwise pull the focus out of the buffer a fraction of a second after every pause, with nothing
--- on screen to explain it); the explicit `,lv` still syncs, where being brought forward is the point.
---@type { inverse: boolean, reload: "auto"|"push"|"none", status: boolean, forward: "quiet"|"raises"|false }
M.supports = { inverse = false, reload = "auto", status = false, forward = "raises" }

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

--- Which bus name owns this document? Retried, because the answer is not available yet at the moment
--- it is most often asked.
---
--- `,lv` on a closed viewer OPENS evince and then immediately forward-searches into it — but a window
--- registers with the daemon some way into its startup, so the first `FindDocument` answers nothing
--- and, asked once, the whole forward search evaporated silently. That is a race with a window that
--- is on its way, not a failure, so it is waited out; and it is bounded, because a document that will
--- never open must not be asked about for ever.
---@param uri string   file:// URI of the PDF
---@param tries integer
---@param cb fun(owner: string?): nil
---@return nil
function M.find_window(uri, tries, cb)
    local ok = pcall(vim.system, {
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
        local owner = result.code == 0 and (result.stdout or ""):match("'([^']+)'") or nil
        vim.schedule(function()
            if owner or tries <= 1 then
                return cb(owner)
            end
            vim.defer_fn(function()
                M.find_window(uri, tries - 1, cb)
            end, 250)
        end)
    end)
    if not ok then
        cb(nil)
    end
end

--- Forward search over D-Bus: ask the daemon which window owns this document, then tell that window
--- to sync to the source position. Two calls, because the window's bus name is not knowable in
--- advance. Asynchronous throughout — a D-Bus round trip must never block the editor.
---
--- The timestamp argument is passed as 0, which is what the interface calls "no timestamp" — and it
--- is worth being clear that this does NOT keep the focus here: GTK reads 0 as "present now", so the
--- window comes forward every time. That is why `supports.forward` is "raises" and the cursor-follow
--- skips evince entirely; nothing that can be passed here changes it.
---@param ctx LvimTexViewCtx
---@param target { line: integer, col: integer, file: string }
---@return boolean
function M.forward(ctx, target)
    if fn.executable("gdbus") ~= 1 then
        return false
    end
    local uri = "file://" .. ctx.pdf
    M.find_window(uri, 12, function(owner)
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
