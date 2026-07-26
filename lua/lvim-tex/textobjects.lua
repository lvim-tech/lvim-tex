-- lvim-tex: LaTeX text objects (checklist row E1).
-- The selections are driven by the queries this plugin ships (after/queries/latex/textobjects.scm),
-- NOT by the generic node-type layer in lvim-ts: that one is deliberately query-less (it climbs to a
-- configured ancestor TYPE), and LaTeX's interesting ranges cannot be expressed that way — an
-- environment has no `body` node, a math zone's delimiters are one or two characters that belong to
-- the zone node itself, and `\left(…\right)` keeps its delimiters in fields. The query already
-- encodes all of that, so the runtime here is only: run it, keep the captures that contain the
-- cursor, take the innermost.
--
-- Two behaviours worth knowing:
--   • REPEAT EXPANDS. Pressing the same object again in visual mode selects the next enclosing
--     instance (an `\item` inside display math inside an `itemize` walks outward), because the
--     candidate chosen is the smallest one that STRICTLY contains the current selection. In
--     operator-pending mode there is no selection, so it is always the innermost.
--   • `math` and `delimiter` share the `@block` capture (the query cannot know which of the two a
--     consumer wants), so they are told apart here by the node the capture belongs to — the first
--     ancestor that is a math zone (math) or a `\left…\right` / brace / bracket group (delimiter).
--
---@module "lvim-tex.textobjects"

local config = require("lvim-tex.config")
local ts = require("lvim-tex.ts")

local api = vim.api
local fn = vim.fn
local treesitter = vim.treesitter

local M = {}

--- Scope sets for the `@block` capture, in priority order, each with the kind it means.
---@type { set: table<string, boolean>, kind: string }[]
local BLOCK_SCOPES = {
    { set = ts.MATH, kind = "math" },
    { set = ts.DELIMITERS, kind = "delimiter" },
    { set = ts.GROUPS, kind = "delimiter" },
}

--- The object kinds, mapped to the query capture that produces them. `scoped` kinds share a capture
--- and are separated by BLOCK_SCOPES; `fallback` kinds reuse their outer range when the query has no
--- inner capture for them (comments are captured whole).
---@type table<string, { capture: string, scoped: boolean?, fallback: boolean? }>
local KINDS = {
    environment = { capture = "class" },
    command = { capture = "function" },
    math = { capture = "block", scoped = true },
    delimiter = { capture = "block", scoped = true },
    item = { capture = "statement" },
    parameter = { capture = "parameter" },
    comment = { capture = "comment", fallback = true },
}

--- Which kind a `@block` capture belongs to: the first ancestor of the capture's own node that is a
--- math zone or a delimiter/group node decides. For an `inner` capture built from the run of siblings
--- BETWEEN two delimiters (the grammar has no body node, so the query anchors on siblings) the
--- container is the parent — the sibling itself may well be a group, which would answer "delimiter"
--- for what is really a math body.
---@param node TSNode
---@param part "inner"|"outer"
---@param offset boolean  the capture carried #offset! metadata (so the node IS the container)
---@return string?
local function block_kind(node, part, offset)
    local start = node
    if part == "inner" and not offset then
        start = node:parent() or node
    end
    local found, index = ts.ancestor_any(start, {
        BLOCK_SCOPES[1].set,
        BLOCK_SCOPES[2].set,
        BLOCK_SCOPES[3].set,
    })
    if not found or not index then
        return nil
    end
    return BLOCK_SCOPES[index].kind
end

--- The range one capture stands for: the `#offset!` metadata when the query trimmed the node's own
--- delimiters, else the span from the first captured node to the last (a quantified `_+` capture — a
--- body named as "every sibling between the delimiters" — reports several nodes).
---@param nodes TSNode[]
---@param buf integer
---@param meta table?  the capture's query metadata
---@return integer[]  { start_row, start_col, end_row, end_col }
---@return boolean    the range came from #offset! metadata
local function capture_range(nodes, buf, meta)
    if meta ~= nil and (meta.range ~= nil or meta.offset ~= nil) then
        -- Core applies the offset and answers with a Range6 (the byte offsets appended); only the
        -- four row/column values are of interest here.
        local r = treesitter.get_range(nodes[1], buf, meta)
        return { r[1], r[2], r[4], r[5] }, true
    end
    local sr, sc = nodes[1]:start()
    local _, _, er, ec = nodes[#nodes]:range()
    return { sr, sc, er, ec }, false
end

--- An empty range (`$$`, `{}`) is not a selection: offering it would collapse the cursor onto a
--- delimiter and swallow the operator.
---@param range integer[]
---@return boolean
local function empty(range)
    return range[1] > range[3] or (range[1] == range[3] and range[2] >= range[4])
end

--- Does `outer` fully contain `inner`?
---@param outer integer[]
---@param inner integer[]
---@return boolean
local function encloses(outer, inner)
    return ts.cmp(outer[1], outer[2], inner[1], inner[2]) <= 0 and ts.cmp(outer[3], outer[4], inner[3], inner[4]) >= 0
end

--- Every range the query gives for `kind`/`part` around the cursor, innermost first.
---
--- The membership test is always made against the OUTER range, even when the INNER one is asked for:
--- the cursor belongs to the object as a whole, so `ic` works with the cursor on `\frac` and `i$`
--- with the cursor on the `$` — the same rule as vim's own `i(`.
---
--- The query is run over the CURSOR'S ROW only: a candidate has to contain the cursor, so it has to
--- intersect that row, and bounding the iteration keeps a large document's cost off the keystroke.
---@param buf integer
---@param row integer  0-based cursor row
---@param col integer  0-based cursor column
---@param kind string
---@param part "inner"|"outer"
---@return integer[][]  ranges { start_row, start_col, end_row, end_col }
function M.ranges(buf, row, col, kind, part)
    local spec = KINDS[kind]
    local root = spec and ts.root(buf)
    if not root then
        return {}
    end
    local query = treesitter.query.get("latex", "textobjects")
    if not query then
        return {}
    end

    local wanted = spec.capture .. "." .. part
    local outer_name = spec.capture .. ".outer"
    -- A kind whose query has no inner capture (comments are captured whole) reuses its outer range.
    local alt = (spec.fallback and part == "inner") and outer_name or nil
    ---@type integer[][]
    local candidates = {}
    ---@type integer[][]  every outer range of the kind, the membership test for the inner ones
    local outers = {}

    for _, match, metadata in query:iter_matches(root, buf, row, row + 1) do
        for id, nodes in pairs(match) do
            local name = query.captures[id]
            if nodes[1] and (name == wanted or name == alt or name == outer_name) then
                local range, offset = capture_range(nodes, buf, metadata[id])
                local ok_scope = true
                if spec.scoped then
                    ok_scope = block_kind(nodes[1], name:sub(-5) == "inner" and "inner" or "outer", offset) == kind
                end
                if ok_scope and not empty(range) then
                    if name == wanted or name == alt then
                        candidates[#candidates + 1] = range
                    end
                    if name == outer_name then
                        outers[#outers + 1] = range
                    end
                end
            end
        end
    end

    local out = {}
    for _, range in ipairs(candidates) do
        local ok
        if part == "outer" then
            ok = ts.contains(range, row, col)
        else
            -- The inner range belongs to the SMALLEST outer range enclosing it — its own object.
            -- Testing against any enclosing outer instead would let `id` on `\left(a + \frac{x}{2}…`
            -- answer with the fraction's `{2}`, which the cursor is nowhere near.
            local owner
            for _, outer in ipairs(outers) do
                if encloses(outer, range) and (not owner or ts.size(outer) < ts.size(owner)) then
                    owner = outer
                end
            end
            ok = owner ~= nil and ts.contains(owner, row, col)
        end
        if ok then
            out[#out + 1] = range
        end
    end

    table.sort(out, function(a, b)
        return ts.size(a) < ts.size(b)
    end)
    return out
end

--- The active visual selection as a 0-based, end-EXCLUSIVE range, or nil when not in visual mode.
---@return integer[]?
local function selection()
    if not fn.mode():find("[vV\22]") then
        return nil
    end
    local anchor = fn.getpos("v")
    local cursor = fn.getpos(".")
    local sr, sc = anchor[2] - 1, anchor[3] - 1
    local er, ec = cursor[2] - 1, cursor[3] - 1
    if ts.cmp(sr, sc, er, ec) > 0 then
        sr, sc, er, ec = er, ec, sr, sc
    end
    return { sr, sc, er, ec + 1 }
end

--- Does `range` strictly contain `inner` (same range does not count)?
---@param range integer[]
---@param inner integer[]
---@return boolean
local function strictly_contains(range, inner)
    if ts.cmp(range[1], range[2], inner[1], inner[2]) > 0 then
        return false
    end
    if ts.cmp(range[3], range[4], inner[3], inner[4]) < 0 then
        return false
    end
    return ts.size(range) > ts.size(inner)
end

--- Establish a charwise visual selection over a 0-based, end-exclusive range. Works for both the
--- visual and the operator-pending mode: a pending operator consumes the selection this leaves.
---@param range integer[]
---@return nil
local function select_range(range)
    local sr, sc, er, ec = range[1], range[2], range[3], range[4]
    -- A range ending at column 0 really ends on the line above (the end column is exclusive).
    if ec == 0 and er > sr then
        er = er - 1
        ec = #(api.nvim_buf_get_lines(0, er, er + 1, false)[1] or "")
    end
    -- Re-running `v` while already visual TOGGLES the mode off, so leave any selection first.
    if fn.mode():find("[vV\22]") then
        vim.cmd("normal! \27")
    end
    fn.setpos(".", { 0, sr + 1, sc + 1, 0 })
    vim.cmd("normal! v")
    fn.setpos(".", { 0, er + 1, math.max(ec, 1), 0 })
end

--- Select the text object `kind`/`part` around the cursor. A no-op when nothing matches, so the key
--- simply does nothing rather than selecting something surprising.
---@param kind string   environment|command|math|delimiter|item|parameter|comment
---@param part "inner"|"outer"
---@return boolean  true when something was selected
function M.select(kind, part)
    local buf, row, col = ts.cursor()
    local candidates = M.ranges(buf, row, col, kind, part)
    if #candidates == 0 then
        return false
    end
    local current = selection()
    -- Without a selection the innermost candidate wins. With one, the first candidate that STRICTLY
    -- encloses it wins — and when nothing encloses it any further the innermost stays, so pressing
    -- the object once more at the outermost level is idempotent instead of losing the selection.
    local pick = candidates[1]
    if current then
        for _, range in ipairs(candidates) do
            if strictly_contains(range, current) then
                pick = range
                break
            end
        end
    end
    select_range(pick)
    return true
end

--- Install the buffer-local text-object maps (operator-pending + visual only, so normal-mode keys
--- are untouched). Idempotent per buffer.
---@param buf integer
---@return nil
function M.attach(buf)
    if not config.textobjects.enabled or not ts.is_latex(buf) or vim.b[buf].lvim_tex_textobjects then
        return
    end
    vim.b[buf].lvim_tex_textobjects = true
    local keys = config.keys.textobjects or {}
    local outer, inner = keys.outer or "a", keys.inner or "i"
    for kind in pairs(KINDS) do
        local suffix = keys[kind]
        if suffix and suffix ~= "" then
            for part, prefix in pairs({ outer = outer, inner = inner }) do
                vim.keymap.set({ "x", "o" }, prefix .. suffix, function()
                    M.select(kind, part)
                end, {
                    buffer = buf,
                    silent = true,
                    desc = ("lvim-tex: %s %s"):format(part, kind),
                })
            end
        end
    end
end

return M
