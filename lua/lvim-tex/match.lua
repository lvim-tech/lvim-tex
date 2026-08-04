-- lvim-tex: `%`-style pair matching for LaTeX (checklist rows S8 and N5).
-- Vim's own `%` knows brackets; it does not know that `\begin{align}` closes with `\end{align}`, that
-- `\left(` closes with `\right)`, or that a `$` opens a zone that another `$` closes. Nothing in the
-- ecosystem provided this (an ecosystem-wide search found no treesitter matchparen anywhere), so it
-- is owned here — and owned STRUCTURALLY: the pair comes from the parse tree, so a `\end{…}` inside a
-- verbatim block or a comment is not a match, and a mismatched nesting cannot fool it.
--
-- `%` stays USEFUL everywhere: when the cursor is not on a LaTeX pair delimiter the key falls through
-- to the built-in `%`, so brackets keep working exactly as before.
--
-- The optional highlight (config.matchparen, off by default) is an EPHEMERAL decoration provider —
-- the ecosystem's canon for per-redraw painting: nothing is stored in the buffer, so there is no
-- extmark churn per keystroke and no state to clean up when the cursor moves away.
--
---@module "lvim-tex.match"

local config = require("lvim-tex.config")
local ts = require("lvim-tex.ts")

local api = vim.api
local fn = vim.fn

local M = {}

---@class LvimTexPair
---@field open  integer[]  { start_row, start_col, end_row, end_col } of the opening delimiter
---@field close integer[]  the same for the closing delimiter
---@field node  TSNode     the construct both belong to

--- The range spanning a run of nodes (nil-safe): used where a delimiter is more than one token,
--- e.g. `\left` + `(`.
---@param first TSNode?
---@param last TSNode?
---@return integer[]?
local function span(first, last)
    if not first then
        return nil
    end
    last = last or first
    local sr, sc = first:start()
    local _, _, er, ec = last:range()
    return { sr, sc, er, ec }
end

--- The opening / closing delimiter ranges of a construct, or nil when the node is not a pair.
---@param node TSNode
---@return LvimTexPair?
local function pair_of(node)
    local kind = node:type()
    if ts.ENVIRONMENTS[kind] then
        local open = span(ts.field(node, "begin"))
        local close = span(ts.field(node, "end"))
        if open and close then
            return { open = open, close = close, node = node }
        end
        return nil
    end
    if ts.DELIMITERS[kind] then
        -- `\left(` … `\right)`: the modifier and the delimiter are separate fields, and the pair is
        -- both of them together — landing on `\left` alone would leave the cursor beside the glyph.
        local open = span(ts.field(node, "left_command"), ts.field(node, "left_delimiter"))
        local close = span(ts.field(node, "right_command"), ts.field(node, "right_delimiter"))
        if open and close then
            return { open = open, close = close, node = node }
        end
        return nil
    end
    if kind == "inline_formula" or kind == "displayed_equation" or ts.GROUPS[kind] then
        -- `$`/`$`, `\[`/`\]`, `{`/`}`, `[`/`]` — the first and last child are the delimiters
        -- themselves (all anonymous tokens).
        local count = node:child_count()
        if count < 2 then
            return nil
        end
        local first, last = node:child(0), node:child(count - 1)
        if not first or not last or first:named() or last:named() then
            return nil
        end
        return { open = span(first), close = span(last), node = node }
    end
    return nil
end

--- The innermost pair whose OPENING or CLOSING delimiter the cursor sits on, plus which side it is
--- on. Being merely INSIDE a construct is not a match: `%` is "jump to the other end of the thing I
--- am standing on", and matching from the body would make it jump out of every enclosing environment
--- in turn.
---@param buf integer
---@param row integer  0-based
---@param col integer  0-based
---@return LvimTexPair?
---@return "open"|"close"|nil
function M.pair_at(buf, row, col)
    local node = ts.node_at(buf, row, col)
    while node do
        local pair = pair_of(node)
        if pair then
            if ts.contains(pair.open, row, col) then
                return pair, "open"
            end
            if ts.contains(pair.close, row, col) then
                return pair, "close"
            end
        end
        node = node:parent()
    end
    return nil, nil
end

--- Jump to the other end of the pair under the cursor; falls through to the built-in `%` when the
--- cursor is not on a LaTeX delimiter.
---@return boolean  true when a LaTeX pair was matched
function M.jump()
    local buf, row, col = ts.cursor()
    ---@type LvimTexPair?, ("open"|"close")?
    local pair, side
    if ts.is_latex(buf) then
        pair, side = M.pair_at(buf, row, col)
    end
    if not pair or not side then
        -- `normal!` — the built-in behaviour, never this mapping again.
        pcall(vim.cmd.normal, { bang = true, args = { "%" } })
        return false
    end
    local target = side == "open" and pair.close or pair.open
    if fn.mode(1) == "n" then
        vim.cmd("normal! m'")
    end
    api.nvim_win_set_cursor(0, { target[1] + 1, target[2] })
    return true
end

---@type integer  the highlight's own namespace (also the decoration provider's id)
local ns = api.nvim_create_namespace("LvimTexMatch")

---@type boolean  the decoration provider has been installed
local provider = false

--- Paint both delimiters of the pair under the cursor, per redraw, with ephemeral extmarks.
---@return nil
local function install_provider()
    if provider then
        return
    end
    provider = true
    api.nvim_set_decoration_provider(ns, {
        on_win = function(_, win, buf, _, _)
            if not config.matchparen.enabled or win ~= api.nvim_get_current_win() then
                return false
            end
            if not api.nvim_buf_is_valid(buf) or not ts.is_latex(buf) then
                return false
            end
            local pos = api.nvim_win_get_cursor(win)
            local pair = M.pair_at(buf, pos[1] - 1, pos[2])
            if not pair then
                return false
            end
            for _, range in ipairs({ pair.open, pair.close }) do
                pcall(api.nvim_buf_set_extmark, buf, ns, range[1], range[2], {
                    end_row = range[3],
                    end_col = range[4],
                    hl_group = config.matchparen.highlight,
                    priority = config.matchparen.priority,
                    ephemeral = true,
                })
            end
            return false
        end,
    })
end

--- Turn the matching-pair highlight on or off at runtime (`:LvimTex matchparen`).
---@param on boolean?  nil toggles
---@return boolean  the new state
function M.toggle_highlight(on)
    ---@type boolean
    local enabled
    if on == nil then
        enabled = not config.matchparen.enabled
    else
        enabled = on
    end
    config.matchparen.enabled = enabled
    vim.cmd("redraw!")
    return enabled
end

--- Install the buffer-local `%` map and (once) the highlight provider. Idempotent per buffer.
---@param buf integer
---@return nil
function M.attach(buf)
    if not ts.is_latex(buf) or vim.b[buf].lvim_tex_match then
        return
    end
    vim.b[buf].lvim_tex_match = true
    -- The provider is installed whatever `matchparen.enabled` says and checks the flag on every
    -- redraw, so `:LvimTex matchparen` takes effect immediately instead of only in buffers opened
    -- afterwards. Its first act when the feature is off is to return.
    install_provider()
    local lhs = config.keys.match
    if lhs and lhs ~= "" then
        vim.keymap.set({ "n", "x", "o" }, lhs, function()
            M.jump()
        end, {
            buffer = buf,
            silent = true,
            desc = "lvim-tex: jump to the matching \\begin/\\end, delimiter or math bound",
        })
    end
end

return M
