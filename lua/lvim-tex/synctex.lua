-- lvim-tex: SYNCTEX — the two-way map between a place in the source and a place in the PDF.
--
-- TeX throws away the correspondence between what you wrote and what was typeset; `-synctex=1` makes
-- the engine record it in `<jobname>.synctex.gz`, and the `synctex` utility is the only thing that
-- reads that format. Both directions therefore go through it, and this module is the ONE place that
-- knows its command line and its output shape:
--
--   FORWARD   `synctex view -i <line>:<col>:<file> -o <pdf>`   → Page / x / y
--   INVERSE   `synctex edit -o <page>:<x>:<y>:<pdf>`           → Input / Line / Column
--
-- COORDINATES. `x` / `y` are PDF points measured from the TOP-LEFT of the page and the page number is
-- 1-based — exactly the contract lvim-preview's `Handle:synctex` documents, so a forward result is
-- handed over unchanged. Nothing here converts anything.
--
-- PATHS. `synctex` matches the name the ENGINE recorded, and it only reliably resolves ABSOLUTE ones
-- (`./main.tex` gives "No tag for ./main.tex" against a log that recorded it from another directory).
-- Every path is therefore made absolute before it is handed over, and the child runs in the root's
-- directory so a relative `Output:` in the reply still resolves.
--
-- HOW A VIEWER REACHES BACK. An external viewer runs a COMMAND when you ctrl-click, so the editor
-- must be addressable from a shell. Neovim already is: `v:servername` names its socket, and
-- `nvim --server <socket> --remote-expr <expr>` evaluates in the running instance. There is no shim
-- script on disk and no `nvr` dependency — `M.editor_command` builds that string, with each viewer's
-- own placeholders substituted in. Our default viewer needs none of it: it is a page on lvim-preview's
-- own websocket, which delivers the click straight to `M.inverse`.
--
---@module "lvim-tex.synctex"

local config = require("lvim-tex.config")
local root_mod = require("lvim-tex.root")
local state = require("lvim-tex.state")

local api = vim.api
local fn = vim.fn
local fs = vim.fs

local M = {}

--- Notify, gated by `config.notify`.
---@param msg string
---@param level integer?
---@return nil
local function notify(msg, level)
    if config.notify then
        vim.notify("lvim-tex: " .. msg, level or vim.log.levels.INFO)
    end
end

--- Is the `synctex` utility usable?
---@return boolean ok, string? detail
function M.available()
    local bin = config.synctex.bin
    if fn.executable(bin) ~= 1 then
        return false, ("%s is not on PATH — it ships with every TeX distribution"):format(bin)
    end
    return true, nil
end

--- Parse a `synctex` reply into its `Key:value` fields. The utility prints a banner line, a
--- `SyncTeX result begin` / `end` frame and one field per line; anything outside that shape is noise
--- from a warning, which is why a missing field is nil rather than an error.
---@param out string
---@return table<string, string>
local function fields(out)
    local map = {}
    for line in (out or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^(%a+):%s*(.*)$")
        if key and not map[key] then
            map[key] = value
        end
    end
    return map
end

--- Run `synctex` with `args` in `cwd` and hand the parsed fields to `done`.
---@param args string[]
---@param cwd string
---@param done fun(f: table<string, string>, code: integer): nil
---@return nil
local function run(args, cwd, done)
    local argv = { config.synctex.bin }
    vim.list_extend(argv, args)
    vim.system(argv, { cwd = cwd, text = true }, function(result)
        vim.schedule(function()
            done(fields((result.stdout or "") .. (result.stderr or "")), result.code)
        end)
    end)
end

--- FORWARD: where in the PDF does `file:line:col` end up?
---
--- `synctex` answers for the position it can place, which is usually the start of the paragraph the
--- line belongs to — that is the granularity the format records, not a rounding error here.
---@param root string
---@param file string   absolute path of the source file
---@param lnum integer   1-based
---@param col integer    1-based
---@param done fun(target: { page: integer, x: number, y: number }?, err: string?): nil
---@return nil
function M.view(root, file, lnum, col, done)
    local ok, why = M.available()
    if not ok then
        return done(nil, why)
    end
    local pdf = root_mod.pdf(root, state.project(root).target)
    if fn.filereadable(pdf) ~= 1 then
        return done(nil, "no PDF yet — build first")
    end
    run({ "view", "-i", ("%d:%d:%s"):format(lnum, math.max(1, col), file), "-o", pdf }, fs.dirname(root), function(f)
        local page = tonumber(f.Page)
        if not page then
            -- The commonest cause by far: this file was never part of the build that produced the
            -- current PDF, so the engine recorded no tag for it.
            return done(nil, ("%s is not in the PDF's SyncTeX data — rebuild"):format(fs.basename(file)))
        end
        done({ page = page, x = tonumber(f.x) or 0, y = tonumber(f.y) or 0 }, nil)
    end)
end

--- Put the cursor on `file:lnum` and make that window current.
---
--- Reuses a window already showing the file rather than replacing the current buffer: an inverse
--- search arrives while the user is looking at something, and taking their window away is not what
--- "show me this line" means.
---@param file string
---@param lnum integer
---@param col integer?
---@return nil
function M.jump(file, lnum, col)
    if fn.filereadable(file) ~= 1 then
        notify(("inverse search names a file that is not there: %s"):format(file), vim.log.levels.WARN)
        return
    end
    local target = fs.normalize(fn.fnamemodify(file, ":p"))
    for _, win in ipairs(api.nvim_list_wins()) do
        local name = api.nvim_buf_get_name(api.nvim_win_get_buf(win))
        if name ~= "" and fs.normalize(name) == target then
            api.nvim_set_current_win(win)
            pcall(api.nvim_win_set_cursor, win, { math.max(1, lnum), math.max(0, (col or 1) - 1) })
            vim.cmd("normal! zz")
            return
        end
    end
    vim.cmd.edit(fn.fnameescape(target))
    pcall(api.nvim_win_set_cursor, 0, { math.max(1, lnum), math.max(0, (col or 1) - 1) })
    vim.cmd("normal! zz")
end

--- INVERSE from a PDF POSITION: resolve it through `synctex edit` and jump.
--- This is the path our own preview page takes — it can only report where it was clicked.
---@param pdf string   absolute path of the PDF
---@param page integer 1-based
---@param x number     PDF points from the page's top-left
---@param y number
---@return nil
function M.inverse(pdf, page, x, y)
    if not config.synctex.inverse then
        return
    end
    local ok, why = M.available()
    if not ok then
        notify(why or "synctex is unavailable", vim.log.levels.WARN)
        return
    end
    local spec = ("%d:%f:%f:%s"):format(page, x, y, pdf)
    run({ "edit", "-o", spec }, fs.dirname(pdf), function(f)
        local lnum = tonumber(f.Line)
        if not f.Input or not lnum then
            notify("inverse search found nothing at that point", vim.log.levels.WARN)
            return
        end
        local col = tonumber(f.Column) or -1
        M.jump(f.Input, lnum, col > 0 and col or 1)
    end)
end

--- INVERSE from a FILE AND LINE — the entry point an EXTERNAL viewer calls.
---
--- Those viewers run `synctex` themselves (that is what their own `-x` / `--editor-cmd` setting is
--- for) and hand over the answer, so this side must not re-resolve anything. It is public and stable
--- because its name is embedded in viewer configuration that outlives this session: renaming it
--- breaks a setting the user pasted into a viewer's preferences.
---@param file string
---@param lnum integer|string   viewers substitute a raw number into the command string
---@param col integer|string?
---@return boolean ok  always true, so `--remote-expr` prints something harmless
function M.inverse_file_line(file, lnum, col)
    if not config.synctex.inverse then
        return true
    end
    vim.schedule(function()
        M.jump(file, tonumber(lnum) or 1, tonumber(col) or 1)
    end)
    return true
end

--- The command an external viewer runs to reach this Neovim, with `file` / `line` substituted for
--- that viewer's own placeholders.
---
--- Returns nil when this instance has no server socket (`nvim --listen ""`), which is the one case
--- where inverse search cannot work at all — health says so rather than handing out a broken string.
---@param placeholder { file: string, line: string }  e.g. { file = "%{input}", line = "%{line}" }
---@return string?
function M.editor_command(placeholder)
    local server = vim.v.servername
    if not server or server == "" then
        return nil
    end
    return ("%s --server %s --remote-expr \"v:lua.require('lvim-tex.synctex').inverse_file_line('%s',%s)\""):format(
        fn.exepath("nvim") ~= "" and fn.exepath("nvim") or "nvim",
        server,
        placeholder.file,
        placeholder.line
    )
end

return M
