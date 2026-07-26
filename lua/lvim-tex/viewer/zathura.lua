-- lvim-tex: the zathura viewer.
--
-- The best-behaved external viewer for TeX work: it reloads the file by itself, takes a SyncTeX
-- position on the command line, and calls an editor back on ctrl-click — all through documented flags
-- (verified against the local binary's `--help`).
--
--   FORWARD   a running instance is addressed by PID: `--synctex-forward=<line>:<col>:<file>
--             --synctex-pid=<pid>` makes THAT window jump and flash the position. Without the pid a
--             second window would open instead, which is why forward search needs a launch we own.
--   INVERSE   `-x <command>` is accepted at LAUNCH only, so the callback is built there. zathura
--             substitutes `%{input}`, `%{line}` and `%{column}` itself and runs the result through a
--             shell — no shim script, and no `nvr`: the command is `nvim --server … --remote-expr …`.
--   RELOAD    automatic; zathura watches the file. Pushing a reload would be a second, racing one.
--
---@module "lvim-tex.viewer.zathura"

local external = require("lvim-tex.viewer.external")
local synctex = require("lvim-tex.synctex")

local M = {}

M.name = "zathura"

---@type { inverse: boolean, reload: "auto"|"push"|"none", status: boolean }
M.supports = { inverse = true, reload = "auto", status = false }

--- Is zathura installed?
---@return boolean ok, string? detail
function M.available()
    return external.available(M.name)
end

--- Open the PDF, teaching the instance how to reach this editor back.
---@param ctx LvimTexViewCtx
---@return boolean ok, string? err
function M.open(ctx)
    local spec = external.spec(M.name)
    local argv = { spec.bin }
    local callback = synctex.editor_command({ file = "%{input}", line = "%{line}" })
    if callback then
        argv[#argv + 1] = "-x"
        argv[#argv + 1] = callback
    end
    external.extend(argv, spec.args)
    argv[#argv + 1] = ctx.pdf
    return external.launch(M.name, ctx.pdf, argv, vim.fs.dirname(ctx.root))
end

--- Is our zathura still showing this PDF?
---@param ctx LvimTexViewCtx
---@return boolean
function M.is_alive(ctx)
    return external.is_alive(M.name, ctx.pdf)
end

--- Jump the OPEN window to a position. Addressed by pid, so the instance we launched moves instead of
--- a new one appearing; a viewer we did not launch has no pid we could name.
---@param ctx LvimTexViewCtx
---@param target { line: integer, col: integer, file: string }
---@return boolean
function M.forward(ctx, target)
    if not M.is_alive(ctx) then
        return false
    end
    local spec = external.spec(M.name)
    local handle = external.handle(M.name, ctx.pdf)
    local argv = {
        spec.bin,
        ("--synctex-forward=%d:%d:%s"):format(target.line, math.max(1, target.col), target.file),
    }
    if handle and handle.pid then
        argv[#argv + 1] = ("--synctex-pid=%d"):format(handle.pid)
    end
    argv[#argv + 1] = ctx.pdf
    return external.tell(argv, vim.fs.dirname(ctx.root))
end

--- Close our window.
---@param ctx LvimTexViewCtx
---@return nil
function M.close(ctx)
    external.close(M.name, ctx.pdf)
end

return M
