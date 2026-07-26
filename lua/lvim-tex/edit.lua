-- lvim-tex: the editing operators (checklist rows E3-E7).
-- Change / delete a surrounding environment, toggle its star, change / delete a surrounding command,
-- cycle the `\left…\right` delimiter modifiers, and toggle a fraction between `\frac{a}{b}` and an
-- inline division. Every one of them rewrites TWO places at once — that is the whole point of the
-- operators, and the reason they are structural: the pairs come from the parse tree, so a `\end{…}`
-- inside a verbatim block or a comment can never be mistaken for the closer.
--
-- ONE UNDO STEP per operation is a hard requirement (`cse` that needs two `u` to revert is a bug), so
-- every operator collects its edits and hands them to `apply()`, which performs them in one call,
-- LAST position first — later ranges stay valid while earlier text shifts underneath them.
--
-- Where the grammar stops, this is explicit about it:
--   • a PLAIN `(`…`)` pair has no node — the parentheses are anonymous sibling tokens — so the
--     delimiter toggle scans siblings with a nesting stack when there is no `math_delimiter`.
--   • an inline division has no node either (`/` is an `operator` token in a flat text run), so the
--     fraction toggle's reverse direction is a small, documented text scanner over the cursor's line.
--
---@module "lvim-tex.edit"

local config = require("lvim-tex.config")
local ts = require("lvim-tex.ts")

local api = vim.api

local M = {}

--- Notify, gated by `config.notify` (same rule as the rest of the plugin).
---@param msg string
---@param level integer?
---@return nil
local function notify(msg, level)
    if config.notify then
        vim.notify("lvim-tex: " .. msg, level or vim.log.levels.INFO)
    end
end

---@class LvimTexEdit
---@field range integer[]  { start_row, start_col, end_row, end_col }, 0-based, end-exclusive
---@field lines string[]   replacement lines ({} deletes)

--- Apply a set of edits as ONE undo step. They are sorted last-position-first so each range still
--- describes the right text when it is applied.
---@param buf integer
---@param edits LvimTexEdit[]
---@return boolean
local function apply(buf, edits)
    if #edits == 0 then
        return false
    end
    table.sort(edits, function(a, b)
        return ts.cmp(a.range[1], a.range[2], b.range[1], b.range[2]) > 0
    end)
    for _, edit in ipairs(edits) do
        local r = edit.range
        local ok, err = pcall(api.nvim_buf_set_text, buf, r[1], r[2], r[3], r[4], edit.lines)
        if not ok then
            notify(tostring(err), vim.log.levels.ERROR)
            return false
        end
    end
    return true
end

--- Ask for a value through the canonical lvim-ui input (never `vim.ui.input`).
---@param title string
---@param default string
---@param cb fun(value: string): nil
---@return nil
local function prompt(title, default, cb)
    local ok, ui = pcall(require, "lvim-ui")
    if not ok or not ui.input then
        notify("lvim-ui is required for this prompt", vim.log.levels.WARN)
        return
    end
    ui.input({
        title = title,
        default = default,
        callback = function(confirmed, value)
            if confirmed and value and vim.trim(value) ~= "" then
                cb(vim.trim(value))
            end
        end,
    })
end

--- Grow a range to whole lines when nothing but whitespace shares them — so deleting `\begin{x}` on
--- a line of its own removes the line instead of leaving a blank one behind.
---@param buf integer
---@param range integer[]
---@return integer[]
local function expand_to_lines(buf, range)
    local first = api.nvim_buf_get_lines(buf, range[1], range[1] + 1, false)[1] or ""
    local last = api.nvim_buf_get_lines(buf, range[3], range[3] + 1, false)[1] or ""
    if not (first:sub(1, range[2]):match("^%s*$") and last:sub(range[4] + 1):match("^%s*$")) then
        return range
    end
    if range[3] + 1 < api.nvim_buf_line_count(buf) then
        return { range[1], 0, range[3] + 1, 0 }
    end
    if range[1] > 0 then
        local prev = api.nvim_buf_get_lines(buf, range[1] - 1, range[1], false)[1] or ""
        return { range[1] - 1, #prev, range[3], #last }
    end
    return { range[1], 0, range[3], #last }
end

-- ── environments ──────────────────────────────────────────────────────────────

--- The innermost environment around the cursor, skipping the ones named in
--- `config.edit.ignore_environments` — `document` wraps every buffer, so without the skip every
--- environment operator would silently target it whenever the cursor is not inside a real one.
---@param buf integer
---@param row integer
---@param col integer
---@return TSNode?
function M.env_at(buf, row, col)
    local ignore = {}
    for _, name in ipairs(config.edit.ignore_environments or {}) do
        ignore[name] = true
    end
    local node = ts.node_at(buf, row, col)
    while node do
        node = ts.ancestor(node, ts.ENVIRONMENTS)
        if not node then
            return nil
        end
        local name = M.env_name(node, buf)
        if not name or not ignore[name] then
            return node
        end
        node = node:parent()
    end
    return nil
end

--- The name range inside a `\begin{…}` / `\end{…}` group: the `text` node when the grammar produced
--- one, else the empty span between the braces (so `\begin{}` can still be filled in).
---@param delimiter TSNode?  the `begin` or `end` node
---@return integer[]?
local function name_range(delimiter)
    local group = ts.field(delimiter, "name")
    if not group then
        return nil
    end
    local text = group:named_child(0)
    if text then
        return { text:range() }
    end
    local sr, sc, er, ec = group:range()
    return { sr, sc + 1, er, math.max(sc + 1, ec - 1) }
end

--- The environment's name (`itemize`, `align*`, …).
---@param node TSNode  an environment node
---@param buf integer
---@return string?
function M.env_name(node, buf)
    local range = name_range(ts.field(node, "begin"))
    if not range then
        return nil
    end
    local lines = api.nvim_buf_get_text(buf, range[1], range[2], range[3], range[4], {})
    return table.concat(lines, "")
end

--- Rewrite the name of the innermost environment at BOTH ends. With no `name` the canonical input
--- asks for one, prefilled with the current name.
---@param name string?  new environment name (nil prompts)
---@return boolean  true when the buffer was changed
function M.change_env(name)
    local buf, row, col = ts.cursor()
    local node = M.env_at(buf, row, col)
    if not node then
        notify("no surrounding environment", vim.log.levels.WARN)
        return false
    end
    local open = name_range(ts.field(node, "begin"))
    local close = name_range(ts.field(node, "end"))
    if not open or not close then
        notify("this environment has no name group", vim.log.levels.WARN)
        return false
    end
    if not name then
        prompt("Environment name", M.env_name(node, buf) or "", function(value)
            M.change_env(value)
        end)
        return false
    end
    return apply(buf, {
        { range = open, lines = { name } },
        { range = close, lines = { name } },
    })
end

--- Delete the innermost environment's `\begin{…}` and `\end{…}`, keeping the body. A delimiter that
--- had a line to itself takes the line with it.
---@return boolean
function M.delete_env()
    local buf, row, col = ts.cursor()
    local node = M.env_at(buf, row, col)
    if not node then
        notify("no surrounding environment", vim.log.levels.WARN)
        return false
    end
    local open, close = ts.field(node, "begin"), ts.field(node, "end")
    if not open or not close then
        return false
    end
    return apply(buf, {
        { range = expand_to_lines(buf, { open:range() }), lines = {} },
        { range = expand_to_lines(buf, { close:range() }), lines = {} },
    })
end

-- ── stars ─────────────────────────────────────────────────────────────────────

--- Add or remove a trailing `*`.
---@param name string
---@return string
local function flip_star(name)
    if name:sub(-1) == "*" then
        return name:sub(1, -2)
    end
    return name .. "*"
end

--- Toggle the starred form of the construct at the cursor: the innermost environment when there is
--- one, else the innermost command, else the sectioning command whose HEADING row the cursor is on
--- (a `section` node owns everything under it, so anywhere else in the body would be a surprise).
---@return boolean
function M.toggle_star()
    local buf, row, col = ts.cursor()
    local env = M.env_at(buf, row, col)
    if env then
        local open = name_range(ts.field(env, "begin"))
        local close = name_range(ts.field(env, "end"))
        local name = M.env_name(env, buf)
        if open and close and name then
            local flipped = flip_star(name)
            return apply(buf, {
                { range = open, lines = { flipped } },
                { range = close, lines = { flipped } },
            })
        end
    end
    local node = ts.node_at(buf, row, col)
    local cmd = ts.ancestor(node, ts.COMMANDS)
    local target = cmd and M.command_name_node(cmd) or nil
    if not target then
        local section = ts.ancestor(node, ts.SECTIONS)
        if section and section:start() == row then
            target = section:child(0)
        end
    end
    if not target then
        notify("nothing starrable here", vim.log.levels.WARN)
        return false
    end
    return apply(buf, {
        { range = { target:range() }, lines = { flip_star(ts.text(target, buf)) } },
    })
end

-- ── commands ──────────────────────────────────────────────────────────────────

--- The token carrying a command's NAME: `command_name` for a generic command, and the leading
--- anonymous `\…` token for the ones the grammar knows by name (`\label`, `\cite`, …).
---@param node TSNode  a command node
---@return TSNode?
function M.command_name_node(node)
    local first = node:child(0)
    if not first then
        return nil
    end
    if first:type() == "command_name" or not first:named() then
        return first
    end
    return nil
end

--- The command's mandatory groups (`{…}`), in order.
---@param node TSNode
---@return TSNode[]
local function curly_args(node)
    local out = {}
    for child in node:iter_children() do
        local t = child:type()
        if ts.GROUPS[t] and t:sub(1, 5) == "curly" then
            out[#out + 1] = child
        end
    end
    return out
end

--- Rename the innermost command, keeping every argument. With no `name` the canonical input asks for
--- one, prefilled with the current name (no backslash).
---@param name string?  new command name, with or without the leading backslash
---@return boolean
function M.change_cmd(name)
    local buf, row, col = ts.cursor()
    local node = ts.ancestor(ts.node_at(buf, row, col), ts.COMMANDS)
    local target = node and M.command_name_node(node) or nil
    if not target then
        notify("no surrounding command", vim.log.levels.WARN)
        return false
    end
    if not name then
        prompt("Command name", (ts.text(target, buf):gsub("^\\", "")), function(value)
            M.change_cmd(value)
        end)
        return false
    end
    name = name:gsub("^\\", "")
    return apply(buf, { { range = { target:range() }, lines = { "\\" .. name } } })
end

--- Delete the innermost command, keeping the contents of its FIRST mandatory group
--- (`\textbf{bold}` → `bold`). A command without one is removed entirely (`\newpage`).
---@return boolean
function M.delete_cmd()
    local buf, row, col = ts.cursor()
    local node = ts.ancestor(ts.node_at(buf, row, col), ts.COMMANDS)
    if not node then
        notify("no surrounding command", vim.log.levels.WARN)
        return false
    end
    local sr, sc, er, ec = node:range()
    local args = curly_args(node)
    if #args == 0 then
        return apply(buf, { { range = { sr, sc, er, ec }, lines = {} } })
    end
    local gsr, gsc, ger, gec = args[1]:range()
    return apply(buf, {
        -- the tail: from just after the kept group's closing brace to the command's end
        { range = { ger, gec - 1, er, ec }, lines = {} },
        -- the head: from the command's start to just after the kept group's opening brace
        { range = { sr, sc, gsr, gsc + 1 }, lines = {} },
    })
end

-- ── delimiters ────────────────────────────────────────────────────────────────

--- Where `text` sits in the modifier list (matching the LEFT modifier), or nil.
---@param text string
---@return integer?
local function modifier_index(text)
    for i, pair in ipairs(config.edit.delim_modifiers or {}) do
        if pair[1] == text then
            return i
        end
    end
    return nil
end

--- The next entry of the modifier cycle. The cycle is `none → 1 → 2 → … → n → none`, so index 0 is
--- "no modifier" and the arithmetic is modulo n+1 — a single-entry list (the default) therefore
--- toggles `\left(…\right)` on and off, exactly as it should.
---@param index integer  current index (0 = none)
---@param dir integer    1 forward, -1 backward
---@return integer       next index (0 = none)
local function cycle(index, dir)
    local n = #(config.edit.delim_modifiers or {})
    if n == 0 then
        return 0
    end
    return (index + dir) % (n + 1)
end

--- A leaf token's text, or nil when the node is not a leaf. `\{`, `\langle` and friends parse as a
--- command whose only child is its name, so those count as leaves too.
---@param node TSNode
---@param buf integer
---@return string?
local function leaf_text(node, buf)
    local count = node:child_count()
    if count == 0 then
        return ts.text(node, buf)
    end
    if count == 1 and node:type() == "generic_command" then
        local only = node:child(0)
        if only and only:type() == "command_name" then
            return ts.text(only, buf)
        end
    end
    return nil
end

--- The innermost PLAIN delimiter pair around the cursor — the case the grammar gives no node for.
--- Siblings are scanned with one stack per configured pair: the first closer that pops an opener
--- into a span containing the cursor IS the innermost pair, because inner pairs always close first.
---@param buf integer
---@param row integer
---@param col integer
---@return { open: integer[], close: integer[] }?
local function plain_pair(buf, row, col)
    local node = ts.node_at(buf, row, col)
    local parent = node and node:parent() or nil
    while parent do
        ---@type table<integer, integer[][]>  pair index -> stack of open ranges
        local stacks = {}
        for child in parent:iter_children() do
            local text = leaf_text(child, buf)
            if text then
                for i, pair in ipairs(config.edit.delimiters or {}) do
                    -- A pair whose two delimiters are equal (`|…|`) cannot be nested unambiguously
                    -- and is skipped rather than guessed at.
                    if pair[1] ~= pair[2] then
                        if text == pair[1] then
                            stacks[i] = stacks[i] or {}
                            table.insert(stacks[i], { child:range() })
                        elseif text == pair[2] then
                            local stack = stacks[i]
                            local open = stack and table.remove(stack) or nil
                            if open then
                                local close = { child:range() }
                                if
                                    ts.cmp(open[1], open[2], row, col) <= 0
                                    and ts.cmp(close[3], close[4], row, col) > 0
                                then
                                    return { open = open, close = close }
                                end
                            end
                        end
                    end
                end
            end
        end
        parent = parent:parent()
    end
    return nil
end

--- Cycle the delimiter modifiers of the pair around the cursor (E6). On a `\left…\right` pair the
--- modifiers are replaced (or dropped, closing the cycle); on a plain pair the first (forward) or
--- last (backward) modifier of the list is inserted.
---@param reverse boolean?  walk the cycle backwards
---@return boolean
function M.toggle_delim(reverse)
    local buf, row, col = ts.cursor()
    local dir = reverse and -1 or 1
    local mods = config.edit.delim_modifiers or {}
    local node = ts.ancestor(ts.node_at(buf, row, col), ts.DELIMITERS)
    if node then
        local left = ts.field(node, "left_command")
        local right = ts.field(node, "right_command")
        if not left or not right then
            return false
        end
        local index = modifier_index(ts.text(left, buf)) or 0
        local next_index = cycle(index, dir)
        local pair = mods[next_index]
        return apply(buf, {
            { range = { left:range() }, lines = { pair and pair[1] or "" } },
            { range = { right:range() }, lines = { pair and pair[2] or "" } },
        })
    end
    local plain = plain_pair(buf, row, col)
    if not plain then
        notify("no delimiter pair around the cursor", vim.log.levels.WARN)
        return false
    end
    local pair = mods[reverse and #mods or 1]
    if not pair then
        return false
    end
    return apply(buf, {
        { range = { plain.open[1], plain.open[2], plain.open[1], plain.open[2] }, lines = { pair[1] } },
        { range = { plain.close[1], plain.close[2], plain.close[1], plain.close[2] }, lines = { pair[2] } },
    })
end

-- ── fractions ─────────────────────────────────────────────────────────────────

--- Does an operand need parentheses when it becomes one side of an inline division? A single token
--- (one character, or one command) reads the same either way; anything with structure does not.
---@param text string
---@return boolean
local function needs_parens(text)
    local trimmed = vim.trim(text)
    if trimmed == "" then
        return false
    end
    if trimmed:match("^[%w%.]$") or trimmed:match("^\\%a+$") then
        return false
    end
    -- Already one balanced group: `(a+b)` / `{a+b}` stay as they are.
    if trimmed:match("^%b()$") or trimmed:match("^%b{}$") then
        return false
    end
    return true
end

--- The fraction command around the cursor, when its name is one of `config.edit.frac_commands` and
--- it has at least two mandatory groups.
---@param buf integer
---@param row integer
---@param col integer
---@return TSNode?  node
---@return TSNode[]? args
local function frac_at(buf, row, col)
    local node = ts.node_at(buf, row, col)
    while node do
        node = ts.ancestor(node, ts.COMMANDS)
        if not node then
            return nil, nil
        end
        local name_node = M.command_name_node(node)
        local name = name_node and ts.text(name_node, buf):gsub("^\\", "") or ""
        if vim.tbl_contains(config.edit.frac_commands or {}, name) then
            local args = curly_args(node)
            if #args >= 2 then
                return node, args
            end
        end
        node = node:parent()
    end
    return nil, nil
end

--- The text INSIDE a `{…}` group.
---@param buf integer
---@param group TSNode
---@return string
local function group_text(buf, group)
    local sr, sc, er, ec = group:range()
    return table.concat(api.nvim_buf_get_text(buf, sr, sc + 1, er, math.max(sc + 1, ec - 1), {}), "\n")
end

--- Scan an operand LEFT of `at` (1-based column, exclusive) on `line`: a balanced group, a command,
--- or a run of word characters.
---@param line string
---@param at integer  1-based index just past the operand's end
---@return integer? start  1-based
---@return string? text    the operand with a surrounding group stripped
local function operand_left(line, at)
    local i = at
    while i > 0 and line:sub(i, i):match("%s") do
        i = i - 1
    end
    if i == 0 then
        return nil, nil
    end
    local closer = line:sub(i, i)
    local opener = ({ [")"] = "(", ["}"] = "{", ["]"] = "[" })[closer]
    if opener then
        local depth, j = 0, i
        while j > 0 do
            local c = line:sub(j, j)
            if c == closer then
                depth = depth + 1
            elseif c == opener then
                depth = depth - 1
                if depth == 0 then
                    return j, line:sub(j + 1, i - 1)
                end
            end
            j = j - 1
        end
        return nil, nil
    end
    local j = i
    while j > 0 and line:sub(j, j):match("[%w%.]") do
        j = j - 1
    end
    -- A command name: the run of letters is preceded by a backslash.
    if j > 0 and line:sub(j, j) == "\\" then
        j = j - 1
    end
    if j == i then
        return nil, nil
    end
    return j + 1, line:sub(j + 1, i)
end

--- Scan an operand RIGHT of `at` (1-based column, exclusive) on `line`.
---@param line string
---@param at integer  1-based index just before the operand's start
---@return integer? finish  1-based, inclusive
---@return string? text
local function operand_right(line, at)
    local i = at
    while i <= #line and line:sub(i, i):match("%s") do
        i = i + 1
    end
    if i > #line then
        return nil, nil
    end
    local opener = line:sub(i, i)
    local closer = ({ ["("] = ")", ["{"] = "}", ["["] = "]" })[opener]
    if closer then
        local depth, j = 0, i
        while j <= #line do
            local c = line:sub(j, j)
            if c == opener then
                depth = depth + 1
            elseif c == closer then
                depth = depth - 1
                if depth == 0 then
                    return j, line:sub(i + 1, j - 1)
                end
            end
            j = j + 1
        end
        return nil, nil
    end
    local j = i
    if line:sub(j, j) == "\\" then
        j = j + 1
    end
    while j <= #line and line:sub(j, j):match("[%w%.]") do
        j = j + 1
    end
    if j == i then
        return nil, nil
    end
    return j - 1, line:sub(i, j - 1)
end

--- Turn the inline division at the cursor into `\frac{…}{…}`. The division is found by scanning the
--- cursor's line: the `/` under the cursor, else the first one after it, else the last one before —
--- a text scan because the grammar has no division node (`/` is a plain operator token).
---@param buf integer
---@param row integer
---@param col integer
---@return boolean
local function division_to_frac(buf, row, col)
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local slash = nil
    if line:sub(col + 1, col + 1) == "/" then
        slash = col + 1
    else
        slash = line:find("/", col + 1, true)
        if not slash then
            local last = nil
            local from = 1
            while true do
                local found = line:find("/", from, true)
                if not found or found > col then
                    break
                end
                last, from = found, found + 1
            end
            slash = last
        end
    end
    if not slash then
        notify("no fraction or division at the cursor", vim.log.levels.WARN)
        return false
    end
    local left_start, left_text = operand_left(line, slash - 1)
    local right_end, right_text = operand_right(line, slash + 1)
    if not left_start or not right_end or not left_text or not right_text then
        notify("could not read both sides of the division", vim.log.levels.WARN)
        return false
    end
    local replacement = ("\\%s{%s}{%s}"):format(config.edit.frac_command, vim.trim(left_text), vim.trim(right_text))
    return apply(buf, { { range = { row, left_start - 1, row, right_end }, lines = { replacement } } })
end

--- Toggle the fraction at the cursor (E7): `\frac{a}{b}` becomes `a/b` (operands parenthesised only
--- when they are more than a single token), and an inline division becomes `\frac{a}{b}` again.
---@return boolean
function M.toggle_frac()
    local buf, row, col = ts.cursor()
    local node, args = frac_at(buf, row, col)
    if not node or not args then
        return division_to_frac(buf, row, col)
    end
    local numerator = vim.trim(group_text(buf, args[1]))
    local denominator = vim.trim(group_text(buf, args[2]))
    local function wrap(text)
        return needs_parens(text) and ("(" .. text .. ")") or text
    end
    local sr, sc = node:start()
    local _, _, er, ec = args[2]:range()
    local replacement = wrap(numerator) .. config.edit.frac_separator .. wrap(denominator)
    return apply(buf, { { range = { sr, sc, er, ec }, lines = vim.split(replacement, "\n", { plain = true }) } })
end

-- ── keys ──────────────────────────────────────────────────────────────────────

--- The operators, as `config.keys.edit` field -> action.
---@type table<string, { run: fun(), desc: string }>
local OPERATORS = {
    change_env = {
        run = function()
            M.change_env()
        end,
        desc = "change the surrounding environment",
    },
    delete_env = {
        run = function()
            M.delete_env()
        end,
        desc = "delete the surrounding environment",
    },
    toggle_star = {
        run = function()
            M.toggle_star()
        end,
        desc = "toggle the starred form",
    },
    change_cmd = {
        run = function()
            M.change_cmd()
        end,
        desc = "change the surrounding command",
    },
    delete_cmd = {
        run = function()
            M.delete_cmd()
        end,
        desc = "delete the surrounding command",
    },
    toggle_delim = {
        run = function()
            M.toggle_delim(false)
        end,
        desc = "cycle the delimiter modifiers",
    },
    toggle_delim_rev = {
        run = function()
            M.toggle_delim(true)
        end,
        desc = "cycle the delimiter modifiers backwards",
    },
    toggle_frac = {
        run = function()
            M.toggle_frac()
        end,
        desc = "toggle \\frac ⇄ inline division",
    },
}

--- Install the buffer-local operator maps (normal mode — they act on the construct AROUND the
--- cursor, so they take no motion and need no visual variant). Idempotent per buffer.
---@param buf integer
---@return nil
function M.attach(buf)
    if not ts.is_latex(buf) or vim.b[buf].lvim_tex_edit then
        return
    end
    vim.b[buf].lvim_tex_edit = true
    for name, operator in pairs(OPERATORS) do
        local lhs = config.keys.edit[name]
        if lhs and lhs ~= "" then
            vim.keymap.set("n", lhs, operator.run, {
                buffer = buf,
                silent = true,
                desc = "lvim-tex: " .. operator.desc,
            })
        end
    end
end

return M
