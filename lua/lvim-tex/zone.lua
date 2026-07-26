-- lvim-tex.zone: the ONE answer to "is this position inside maths?".
--
-- Half of what a LaTeX plugin does is only correct INSIDE maths — concealing `\alpha` as α, expanding
-- an insert-mode abbreviation, offering a maths text object. Every one of those asks the same
-- question, and asking it in more than one place is how two features end up disagreeing about where a
-- formula ends. So the question lives here, and conceal (S4) and the imaps (E9) both call it.
--
-- The answer is the PARSE TREE's, not a regex's: walk from the node outwards and report whichever
-- zone is reached first. That is what makes `\text{where $\alpha$}` come out right — the walk from
-- `\alpha` meets the inner `inline_formula` before it meets the `text_mode` that suspended maths, so
-- the innermost zone wins with no special-casing. It also means a comment or a verbatim body can
-- never be mistaken for maths: the grammar does not put commands there at all.
--
-- Cost matters, because conceal calls this once per candidate node on every redraw: it is a parent
-- walk over an already-built tree — no query, no allocation, no text extraction.
--
---@module "lvim-tex.zone"

local ts = vim.treesitter

local M = {}

--- Node types that OPEN a maths zone: `$…$` and `\(…\)` (inline_formula), `\[…\]`
--- (displayed_equation), `equation`/`align`/… (math_environment), and a `\left…\right` pair, which
--- the grammar only ever produces inside maths.
---@type table<string, boolean>
M.math_types = {
    inline_formula = true,
    displayed_equation = true,
    math_environment = true,
    math_delimiter = true,
}

--- Node types that SUSPEND maths again — `\text{…}`, `\intertext{…}` and friends are prose typeset
--- inside a formula, so nothing maths-only may fire in them.
---@type table<string, boolean>
M.text_types = {
    text_mode = true,
}

--- Does `node` itself open a maths zone?
---@param node TSNode?
---@return boolean
function M.opens_math(node)
    return node ~= nil and M.math_types[node:type()] == true
end

--- Is `node` inside maths? The node itself counts: `M.in_math_node(inline_formula)` is true.
---@param node TSNode?
---@return boolean
function M.in_math_node(node)
    local n = node
    while n do
        local t = n:type()
        if M.math_types[t] then
            return true
        end
        if M.text_types[t] then
            return false
        end
        n = n:parent()
    end
    return false
end

--- The innermost node that opens the maths zone `node` sits in, or nil when it is not in maths.
--- (The editing and text-object phases need the ZONE, not just the verdict.)
---@param node TSNode?
---@return TSNode?
function M.math_node(node)
    local n = node
    while n do
        local t = n:type()
        if M.math_types[t] then
            return n
        end
        if M.text_types[t] then
            return nil
        end
        n = n:parent()
    end
    return nil
end

--- Is the position `(row, col)` — 0-based, as every treesitter API here is — inside maths?
---
--- `col` may sit one past the end of the line, which is where an insert-mode caller (the imaps) asks
--- from: the node lookup is clamped to the last character so "typing at the end of a formula" answers
--- the same as "standing on its last character".
---@param buf integer   buffer handle (0 = current)
---@param row integer   0-based row
---@param col integer   0-based byte column
---@return boolean
function M.in_math(buf, row, col)
    buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    if not line then
        return false
    end
    local at = math.max(0, math.min(col, #line - 1))
    local ok, node = pcall(ts.get_node, { bufnr = buf, pos = { row, at }, lang = "latex" })
    if not ok then
        return false
    end
    return M.in_math_node(node)
end

--- Is the CURSOR of `win` inside maths? The convenience form every interactive caller wants.
---@param win integer?  window handle (nil/0 = current)
---@return boolean
function M.cursor_in_math(win)
    win = (win == nil or win == 0) and vim.api.nvim_get_current_win() or win
    local pos = vim.api.nvim_win_get_cursor(win)
    return M.in_math(vim.api.nvim_win_get_buf(win), pos[1] - 1, pos[2])
end

return M
