-- lvim-tex: the Skim viewer (macOS).
--
-- Skim's own `displayline` helper is the whole forward-search interface: `displayline -r <line> <pdf>
-- <tex>` opens or reuses the window, jumps to the line and flashes it (`-r` reverts an already-open
-- file so a rebuilt PDF is picked up, `-b` draws the reading bar, `-g` keeps Skim in the background).
--
-- INVERSE SEARCH IS A ONE-TIME MANUAL STEP and cannot be automated: Skim reads it from its own
-- Preferences → Sync pane, not from any command line. `:checkhealth lvim-tex` prints the exact
-- Command and Arguments to paste there, which is the honest form of "supported".
--
-- NOT VERIFIED ON THIS PLATFORM: this machine is Linux. The flags and preference fields come from
-- Skim's documentation; health labels the module accordingly rather than reporting it as ready.
--
---@module "lvim-tex.viewer.skim"

local external = require("lvim-tex.viewer.external")

local fn = vim.fn

local M = {}

M.name = "skim"

---@type { inverse: boolean, reload: "auto"|"push"|"none", status: boolean }
M.supports = { inverse = true, reload = "auto", status = false }

---@type "live"|"docs"|"platform"|"experimental"
M.verified = "platform"

--- Is Skim's helper present? Only on macOS: the binary name would otherwise be meaningless.
---@return boolean ok, string? detail
function M.available()
    if fn.has("mac") ~= 1 then
        return false, "Skim is macOS-only"
    end
    local bin = external.spec(M.name).displayline
    if not bin or fn.executable(bin) ~= 1 then
        return false, ("%s is not on PATH — it ships inside Skim.app"):format(tostring(bin))
    end
    return true, nil
end

--- The Skim preference the user pastes into Preferences → Sync, as `{ command, arguments }`. Health
--- prints it; nothing here can set it.
---@return { command: string, arguments: string }
function M.inverse_setup()
    return {
        command = fn.exepath("nvim") ~= "" and fn.exepath("nvim") or "nvim",
        arguments = ("--server %s --remote-expr \"v:lua.require('lvim-tex.synctex').inverse_file_line('%%file',%%line)\""):format(
            vim.v.servername or ""
        ),
    }
end

--- Open the PDF — `displayline` at line 1, which opens the window when it is not already there.
---@param ctx LvimTexViewCtx
---@return boolean ok, string? err
function M.open(ctx)
    return M.forward(ctx, { line = 1, col = 1, file = ctx.target }) and true or false, nil
end

--- Skim reuses its own window and we never own the process, so liveness is what `displayline` would
--- do anyway: open or reuse. Reported as false so `,lv` always re-invokes it.
---@return boolean
function M.is_alive()
    return false
end

--- Forward search.
---@param ctx LvimTexViewCtx
---@param target { line: integer, col: integer, file: string }
---@return boolean
function M.forward(ctx, target)
    local spec = external.spec(M.name)
    local argv = external.extend({ spec.displayline, "-r" }, spec.args)
    vim.list_extend(argv, { tostring(target.line), ctx.pdf, target.file })
    return external.tell(argv, vim.fs.dirname(ctx.root))
end

--- Nothing to close: the window is Skim's, and we never launched a process of our own.
---@return nil
function M.close() end

return M
