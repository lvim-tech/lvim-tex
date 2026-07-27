-- lvim-tex: the sioyek viewer.
--
-- Single-instance like okular, but it takes the SyncTeX position as plain flags rather than a URL
-- fragment (`--reuse-window --forward-search-file <tex> --forward-search-line <line> <pdf>`), and
-- accepts the inverse-search callback at launch with `--inverse-search`, where it substitutes `%1`
-- for the file and `%2` for the line.
--
-- THE FLAG IS `--reuse-window`, not `--reuse-instance`. The latter is what this module sent until it
-- was run against a real binary, and sioyek does not ignore an unknown option — it refuses to start:
--
--     $ sioyek --reuse-instance file.pdf
--     sioyek: Unknown option 'reuse-instance'.
--
-- so the viewer simply never appeared, with nothing in the editor to say why. Every flag below is now
-- checked against `sioyek --help` on a real 2.0.0 binary: `--reuse-window`, `--nofocus`,
-- `--inverse-search`, `--forward-search-file`, `--forward-search-line`, `--forward-search-column`.
--
-- PARTLY VERIFIED: the command lines are accepted by the installed binary, but the resulting BEHAVIOUR
-- (a window that reuses itself, a forward search that lands where it should, a ctrl-click that reaches
-- back) has not been watched on screen — see `M.verified`.
--
---@module "lvim-tex.viewer.sioyek"

local external = require("lvim-tex.viewer.external")
local synctex = require("lvim-tex.synctex")

local M = {}

M.name = "sioyek"

--- `forward = "quiet"`: sioyek's own `--nofocus` makes a forward search move the window without
--- taking the keyboard focus, so the cursor-follow may drive it.
---@type { inverse: boolean, reload: "auto"|"push"|"none", status: boolean, forward: "quiet"|"raises"|false }
M.supports = { inverse = true, reload = "auto", status = false, forward = "quiet" }

--- How far this module's behaviour has been PROVEN: "live" against a real binary here, "docs" per the
--- viewer's own documentation only, "platform" when it needs an OS this machine is not.
---
--- Still "docs", deliberately. The command lines are now checked against an installed sioyek 2.0.0 —
--- every flag this module sends is accepted, which is more than could be said before — but a viewer
--- is "live" when its BEHAVIOUR has been watched: a reused window, a forward search that lands on
--- the right line, a ctrl-click that reaches the editor. None of that has been seen yet.
---@type "live"|"docs"|"platform"|"experimental"
M.verified = "docs"

--- Is sioyek installed?
---@return boolean ok, string? detail
function M.available()
    return external.available(M.name)
end

--- The shared argv prefix.
---@return string[]
local function base()
    local spec = external.spec(M.name)
    local argv = { spec.bin, "--reuse-window" }
    local callback = synctex.editor_command({ file = "%1", line = "%2" })
    if callback then
        argv[#argv + 1] = "--inverse-search"
        argv[#argv + 1] = callback
    end
    return external.extend(argv, spec.args)
end

--- Open the PDF.
---@param ctx LvimTexViewCtx
---@return boolean ok, string? err
function M.open(ctx)
    local argv = base()
    argv[#argv + 1] = ctx.pdf
    return external.launch(M.name, ctx.pdf, argv, vim.fs.dirname(ctx.root))
end

--- Is the sioyek we launched still running?
---@param ctx LvimTexViewCtx
---@return boolean
function M.is_alive(ctx)
    return external.is_alive(M.name, ctx.pdf)
end

--- Forward search into the reused instance.
---@param ctx LvimTexViewCtx
---@param target { line: integer, col: integer, file: string }
---@return boolean
function M.forward(ctx, target)
    local argv = base()
    vim.list_extend(argv, {
        -- Move the window, do not take the keyboard: a forward search is "put it there", and the
        -- cursor-follow sends one every time the cursor settles.
        "--nofocus",
        "--forward-search-file",
        target.file,
        "--forward-search-line",
        tostring(target.line),
        -- sioyek takes a column as well, and we always have one: the cursor's. It costs nothing and
        -- narrows the target within a line that SyncTeX recorded at more than one point.
        "--forward-search-column",
        tostring(math.max(1, target.col or 1)),
        ctx.pdf,
    })
    return external.tell(argv, vim.fs.dirname(ctx.root))
end

--- Close our window.
---@param ctx LvimTexViewCtx
---@return nil
function M.close(ctx)
    external.close(M.name, ctx.pdf)
end

return M
