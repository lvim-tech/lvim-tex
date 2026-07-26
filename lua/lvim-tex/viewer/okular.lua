-- lvim-tex: the okular viewer.
--
-- okular is SINGLE-INSTANCE by design: `--unique` makes a second invocation address the running
-- window instead of opening another, which is what both opening and forward search rely on here
-- (flags verified against the local binary's `--help`).
--
--   FORWARD   the position travels in the URL fragment: `okular --unique --noraise
--             'file.pdf#src:<line> <texfile>'`. `--noraise` keeps the editor focused — a forward
--             search is "put it there", not "take my attention".
--   INVERSE   `--editor-cmd <string>` sets the callback for THIS document, so no manual step inside
--             okular's settings is needed when we launch it. okular substitutes `%f` (file) and `%l`
--             (line).
--   RELOAD    automatic; okular watches the file.
--
-- Because the instance is shared, `is_alive` is a statement about the process WE launched. A user's
-- own okular showing the same PDF cannot be tracked, and pretending otherwise would make `,lv` open a
-- second window that okular then folds into the first.
--
---@module "lvim-tex.viewer.okular"

local external = require("lvim-tex.viewer.external")
local synctex = require("lvim-tex.synctex")

local M = {}

M.name = "okular"

---@type { inverse: boolean, reload: "auto"|"push"|"none", status: boolean }
M.supports = { inverse = true, reload = "auto", status = false }

--- Is okular installed?
---@return boolean ok, string? detail
function M.available()
    return external.available(M.name)
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

--- Open the PDF.
---@param ctx LvimTexViewCtx
---@return boolean ok, string? err
function M.open(ctx)
    local argv = base()
    argv[#argv + 1] = ctx.pdf
    return external.launch(M.name, ctx.pdf, argv, vim.fs.dirname(ctx.root))
end

--- Is the okular WE launched still running?
---@param ctx LvimTexViewCtx
---@return boolean
function M.is_alive(ctx)
    return external.is_alive(M.name, ctx.pdf)
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

--- Close our window.
---@param ctx LvimTexViewCtx
---@return nil
function M.close(ctx)
    external.close(M.name, ctx.pdf)
end

return M
