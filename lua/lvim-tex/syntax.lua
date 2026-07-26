-- lvim-tex: the syntax-delegation gap-fills — folding and indentation (checklist rows S6, S7).
-- Both features are DELEGATED: the folds come from the latex query bundle's own `folds.scm` through
-- Neovim's `vim.treesitter.foldexpr`, and the indent from the lvim-ts query-indent engine. What was
-- missing was not the engine but the wiring:
--
--   • S6 — lvim-ts turns folding on only through ITS global `fold` option, i.e. for every language at
--     once. A TeX document is exactly the kind of file where structural folds are wanted while they
--     are unwelcome elsewhere, so `fold.enabled` here applies them to TeX buffers alone. The window
--     options are re-applied when the buffer is shown in ANOTHER window, which lvim-ts's one-shot
--     pass over the current windows does not cover.
--   • S7 — the latex query bundle ships NO `indents.scm`; the one this plugin ships
--     (after/queries/latex/indents.scm) is what the engine reads. `indentexpr` is asserted here too,
--     so the query indent also works when lvim-ts's own activation did not run for the buffer.
--     `indent.keys` is the other half: without the right 'indentkeys' a line only re-indents when the
--     user asks with `=`, so typing `\end{…}` would never pull back onto its `\begin{…}`.
--
-- `indent.enabled = false` means "lvim-tex does not touch 'indentexpr'". It does not un-set what
-- another plugin set — lvim-ts applies the same query on its own when it is installed, and that is
-- lvim-ts's own option to turn off; fighting it after the fact would be a patch, not a gate.
--
---@module "lvim-tex.syntax"

local config = require("lvim-tex.config")
local ts = require("lvim-tex.ts")

local api = vim.api
local fn = vim.fn
local treesitter = vim.treesitter

local M = {}

---@type integer  the augroup for the per-buffer window hookup
local augroup = api.nvim_create_augroup("LvimTexSyntax", { clear = true })

--- The indentexpr the lvim-ts query engine is driven by.
---@type string
local INDENTEXPR = "v:lua.require'lvim-ts.core.indent'.indentexpr()"

--- Apply the treesitter fold options to one window.
---@param win integer
---@return nil
local function fold_window(win)
    if not api.nvim_win_is_valid(win) then
        return
    end
    vim.wo[win][0].foldmethod = "expr"
    vim.wo[win][0].foldexpr = "v:lua.vim.treesitter.foldexpr()"
    vim.wo[win][0].foldlevel = config.fold.level
end

--- Turn treesitter folding on for every window currently showing `buf`.
---@param buf integer
---@return boolean  true when the fold options were applied
function M.fold(buf)
    if not config.fold.enabled or not ts.is_latex(buf) or not treesitter.query.get("latex", "folds") then
        return false
    end
    for _, win in ipairs(fn.win_findbuf(buf)) do
        fold_window(win)
    end
    return true
end

--- Point 'indentexpr' at the query-indent engine, when it is available and enabled.
---@param buf integer
---@return boolean  true when the indent options were applied
function M.indent(buf)
    -- `is_latex` is also what registers the filetype → parser mapping, and the query engine resolves
    -- the buffer's parser FROM ITS FILETYPE: without that registration 'indentexpr' would be set and
    -- then answer -1 for every line.
    if not config.indent.enabled or not ts.is_latex(buf) then
        return false
    end
    if not treesitter.query.get("latex", "indents") then
        return false
    end
    if not pcall(require, "lvim-ts.core.indent") then
        return false
    end
    vim.bo[buf].indentexpr = INDENTEXPR
    if config.indent.keys and config.indent.keys ~= "" then
        vim.bo[buf].indentkeys = config.indent.keys
    end
    return true
end

--- What this module actually managed to turn on — the truthful source for `:checkhealth lvim-tex`,
--- since every part of it (the queries, the engine) can be absent.
---@return { fold: boolean, folds_query: boolean, indent: boolean, indents_query: boolean, engine: boolean }
function M.report()
    local indents = treesitter.query.get("latex", "indents") ~= nil
    local folds = treesitter.query.get("latex", "folds") ~= nil
    local engine = (pcall(require, "lvim-ts.core.indent"))
    return {
        fold = config.fold.enabled and folds,
        folds_query = folds,
        indent = config.indent.enabled and indents and engine,
        indents_query = indents,
        engine = engine,
    }
end

--- Apply the fold and indent wiring to a TeX buffer, and keep the (window-local) fold options
--- correct when the buffer is later opened in another window. Idempotent per buffer.
---@param buf integer
---@return nil
function M.attach(buf)
    if not ts.is_latex(buf) or vim.b[buf].lvim_tex_syntax then
        return
    end
    vim.b[buf].lvim_tex_syntax = true
    M.indent(buf)
    if M.fold(buf) then
        api.nvim_create_autocmd("BufWinEnter", {
            group = augroup,
            buffer = buf,
            desc = "lvim-tex: treesitter folds in every window showing this buffer",
            callback = function()
                if config.fold.enabled then
                    fold_window(api.nvim_get_current_win())
                end
            end,
        })
    end
end

return M
