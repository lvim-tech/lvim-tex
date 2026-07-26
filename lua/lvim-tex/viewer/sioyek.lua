-- lvim-tex: the sioyek viewer.
--
-- Single-instance like okular, but it takes the SyncTeX position as plain flags rather than a URL
-- fragment (`--reuse-instance --forward-search-file <tex> --forward-search-line <line> <pdf>`), and
-- accepts the inverse-search callback at launch with `--inverse-search`, where it substitutes `%1`
-- for the file and `%2` for the line.
--
-- NOT VERIFIED ON THIS MACHINE: sioyek is not installed here, so the flags are the ones its own
-- documentation specifies and nothing more. `:checkhealth lvim-tex` says exactly that rather than
-- listing it as ready — see `M.verified`.
--
---@module "lvim-tex.viewer.sioyek"

local external = require("lvim-tex.viewer.external")
local synctex = require("lvim-tex.synctex")

local M = {}

M.name = "sioyek"

---@type { inverse: boolean, reload: "auto"|"push"|"none", status: boolean }
M.supports = { inverse = true, reload = "auto", status = false }

--- How far this module's behaviour has been PROVEN: "live" against a real binary here, "docs" per the
--- viewer's own documentation only, "platform" when it needs an OS this machine is not.
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
    local argv = { spec.bin, "--reuse-instance" }
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
        "--forward-search-file",
        target.file,
        "--forward-search-line",
        tostring(target.line),
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
