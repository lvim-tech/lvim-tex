-- lvim-tex: the SumatraPDF viewer (Windows).
--
-- Sumatra takes both directions on the command line: `-forward-search <tex> <line>` moves an open
-- window to a position, and `-inverse-search "<command> %f %l"` installs the editor callback for the
-- session it is launched with. `-reuse-instance` keeps a second invocation from opening a new window.
--
-- NOT VERIFIED ON THIS PLATFORM: this machine is Linux, so the syntax is Sumatra's documented one.
-- One detail is documented nowhere and ships PROVISIONALLY: whether it reloads a changed file by
-- itself. `supports.reload` is "auto" on that assumption; if a Windows run shows otherwise it becomes
-- "none" plus a manual reload key, which is a data change in this file and nothing else.
--
---@module "lvim-tex.viewer.sumatra"

local external = require("lvim-tex.viewer.external")
local synctex = require("lvim-tex.synctex")

local fn = vim.fn

local M = {}

M.name = "sumatra"

---@type { inverse: boolean, reload: "auto"|"push"|"none", status: boolean }
M.supports = { inverse = true, reload = "auto", status = false }

---@type "live"|"docs"|"platform"|"experimental"
M.verified = "platform"

--- Is SumatraPDF present? Windows only.
---@return boolean ok, string? detail
function M.available()
    if fn.has("win32") ~= 1 and fn.has("win64") ~= 1 then
        return false, "SumatraPDF is Windows-only"
    end
    return external.available(M.name)
end

--- The shared argv prefix, carrying the inverse-search callback.
---@return string[]
local function base()
    local spec = external.spec(M.name)
    local argv = { spec.bin, "-reuse-instance" }
    local callback = synctex.editor_command({ file = "%f", line = "%l" })
    if callback then
        argv[#argv + 1] = "-inverse-search"
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

--- Is the instance we launched still running?
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
    vim.list_extend(argv, { "-forward-search", target.file, tostring(target.line), ctx.pdf })
    return external.tell(argv, vim.fs.dirname(ctx.root))
end

--- Close our window.
---@param ctx LvimTexViewCtx
---@return nil
function M.close(ctx)
    external.close(M.name, ctx.pdf)
end

return M
