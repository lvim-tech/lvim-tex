-- lvim-tex: the evince viewer.
--
-- evince has no SyncTeX command line at all: everything but "open this file" happens over its D-Bus
-- session interface. The daemon maps a PDF path to a window bus name (`FindDocument`), and that
-- window then takes a `SyncView` call carrying the source file and line.
--
-- EXPERIMENTAL, and labelled so in health. evince is not installed on this machine, so the interface
-- names below come from its published D-Bus API and have NOT been exercised against a running daemon.
-- What IS certain is `open` (evince <pdf>) and its automatic reload; forward search is the part that
-- graduates from "experimental" only after a live round trip somewhere evince exists. Inverse search
-- needs the reverse direction (a `SyncSource` signal, which requires holding a monitor process) and is
-- deliberately NOT claimed until that same round trip can be run.
--
---@module "lvim-tex.viewer.evince"

local external = require("lvim-tex.viewer.external")

local fn = vim.fn

local M = {}

M.name = "evince"

---@type { inverse: boolean, reload: "auto"|"push"|"none", status: boolean }
M.supports = { inverse = false, reload = "auto", status = false }

---@type "live"|"docs"|"platform"|"experimental"
M.verified = "experimental"

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
