-- lvim-tex: structural motions (checklist row E2, and the navigation half of N5).
-- Bracket-style jumps between the STRUCTURE the grammar already knows: section headings,
-- environment boundaries, math zones and `\item` entries — forward and backward, to the start or to
-- the end of the unit. They are plain cursor moves, so they work in normal, visual AND
-- operator-pending mode (`d]]` deletes to the next section) and honour a count (`3]m`).
--
-- The positions are collected by ONE walk of the tree per buffer change and cached under the
-- buffer's changedtick: a document with hundreds of sections is walked once after an edit, not once
-- per keystroke. The cache holds numbers only — never nodes — so it keeps no tree alive.
--
---@module "lvim-tex.motion"

local config = require("lvim-tex.config")
local ts = require("lvim-tex.ts")

local api = vim.api
local fn = vim.fn

local M = {}

--- The node-type set each motion kind walks.
---@type table<string, table<string, boolean>>
local KINDS = {
    section = ts.SECTIONS,
    environment = ts.ENVIRONMENTS,
    math = ts.MATH,
    item = ts.ITEMS,
}

--- Per-buffer position cache: `{ tick = changedtick, kinds = { [kind] = ranges } }`.
---@type table<integer, { tick: integer, kinds: table<string, integer[][]> }>
local cache = {}

api.nvim_create_autocmd({ "BufWipeout", "BufDelete" }, {
    group = api.nvim_create_augroup("LvimTexMotion", { clear = true }),
    desc = "lvim-tex: drop the motion position cache with the buffer",
    callback = function(args)
        cache[args.buf] = nil
    end,
})

--- Every range of `types` in the buffer, in document order.
---@param buf integer
---@param types table<string, boolean>
---@return integer[][]
local function collect(buf, types)
    local root = ts.root(buf)
    local out = {}
    if not root then
        return out
    end
    --- Depth-first over NAMED nodes; every unit of interest is a named node, and skipping the
    --- anonymous tokens roughly halves the walk.
    ---@param node TSNode
    local function walk(node)
        if types[node:type()] then
            out[#out + 1] = { node:range() }
        end
        for child in node:iter_children() do
            if child:named() then
                walk(child)
            end
        end
    end
    walk(root)
    table.sort(out, function(a, b)
        return ts.cmp(a[1], a[2], b[1], b[2]) < 0
    end)
    return out
end

--- Cached ranges for a motion kind.
---@param buf integer
---@param kind string
---@return integer[][]
function M.ranges(buf, kind)
    local types = KINDS[kind]
    if not types then
        return {}
    end
    local tick = api.nvim_buf_get_changedtick(buf)
    local entry = cache[buf]
    if not entry or entry.tick ~= tick then
        entry = { tick = tick, kinds = {} }
        cache[buf] = entry
    end
    if not entry.kinds[kind] then
        entry.kinds[kind] = collect(buf, types)
    end
    return entry.kinds[kind]
end

--- The position of a range's LAST character: treesitter's end is exclusive, and a node ending at
--- column 0 really ends on the line above.
---@param buf integer
---@param range integer[]
---@return integer row
---@return integer col
local function last_position(buf, range)
    local row, col = range[3], range[4]
    if col > 0 then
        return row, col - 1
    end
    row = math.max(range[1], row - 1)
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    return row, math.max(0, #line - 1)
end

--- The next / previous position of `kind` relative to `row`,`col`.
---@param buf integer
---@param kind string
---@param dir integer  1 = forward, -1 = backward
---@param part "start"|"end"
---@param row integer  0-based
---@param col integer  0-based
---@return integer? row
---@return integer? col
function M.target(buf, kind, dir, part, row, col)
    local ranges = M.ranges(buf, kind)
    ---@type integer[][]
    local points = {}
    for _, range in ipairs(ranges) do
        if part == "end" then
            local r, c = last_position(buf, range)
            points[#points + 1] = { r, c }
        else
            points[#points + 1] = { range[1], range[2] }
        end
    end
    table.sort(points, function(a, b)
        return ts.cmp(a[1], a[2], b[1], b[2]) < 0
    end)
    if dir > 0 then
        for _, p in ipairs(points) do
            if ts.cmp(p[1], p[2], row, col) > 0 then
                return p[1], p[2]
            end
        end
    else
        for i = #points, 1, -1 do
            local p = points[i]
            if ts.cmp(p[1], p[2], row, col) < 0 then
                return p[1], p[2]
            end
        end
    end
    return nil, nil
end

--- Move the cursor to the next / previous `kind` boundary, `v:count1` times.
---@param kind string   section|environment|math|item
---@param dir integer   1 = forward, -1 = backward
---@param part "start"|"end"
---@return boolean  true when the cursor moved
function M.jump(kind, dir, part)
    local buf, row, col = ts.cursor()
    if not ts.is_latex(buf) then
        return false
    end
    local moved = false
    for _ = 1, vim.v.count1 do
        local r, c = M.target(buf, kind, dir, part, row, col)
        if not r or not c then
            break
        end
        row, col = r, c
        moved = true
    end
    if not moved then
        return false
    end
    -- Keep the jumplist honest for a plain navigation jump. Skipped while an operator is pending
    -- (mode "no…"), where a `normal!` command would cancel the operator instead.
    if fn.mode(1) == "n" then
        vim.cmd("normal! m'")
    end
    api.nvim_win_set_cursor(0, { row + 1, col })
    return true
end

--- The motions, as `config.keys.motion` field -> arguments.
---@type table<string, { kind: string, dir: integer, part: "start"|"end", desc: string }>
local MOTIONS = {
    section_next = { kind = "section", dir = 1, part = "start", desc = "next section" },
    section_prev = { kind = "section", dir = -1, part = "start", desc = "previous section" },
    section_end_next = { kind = "section", dir = 1, part = "end", desc = "next section end" },
    section_end_prev = { kind = "section", dir = -1, part = "end", desc = "previous section end" },
    env_next = { kind = "environment", dir = 1, part = "start", desc = "next environment" },
    env_prev = { kind = "environment", dir = -1, part = "start", desc = "previous environment" },
    env_end_next = { kind = "environment", dir = 1, part = "end", desc = "next environment end" },
    env_end_prev = { kind = "environment", dir = -1, part = "end", desc = "previous environment end" },
    math_next = { kind = "math", dir = 1, part = "start", desc = "next math zone" },
    math_prev = { kind = "math", dir = -1, part = "start", desc = "previous math zone" },
    math_end_next = { kind = "math", dir = 1, part = "end", desc = "next math zone end" },
    math_end_prev = { kind = "math", dir = -1, part = "end", desc = "previous math zone end" },
    item_next = { kind = "item", dir = 1, part = "start", desc = "next \\item" },
    item_prev = { kind = "item", dir = -1, part = "start", desc = "previous \\item" },
}

--- Install the buffer-local motion maps. Idempotent per buffer.
---@param buf integer
---@return nil
function M.attach(buf)
    if not config.motion.enabled or not ts.is_latex(buf) or vim.b[buf].lvim_tex_motion then
        return
    end
    vim.b[buf].lvim_tex_motion = true
    local keys = config.keys.motion or {}
    for name, motion in pairs(MOTIONS) do
        local lhs = keys[name]
        if lhs and lhs ~= "" then
            vim.keymap.set({ "n", "x", "o" }, lhs, function()
                M.jump(motion.kind, motion.dir, motion.part)
            end, {
                buffer = buf,
                silent = true,
                desc = "lvim-tex: " .. motion.desc,
            })
        end
    end
end

return M
