-- lvim-tex.conceal: show a LaTeX source as the maths it means, without changing a byte of it.
--
-- `\sum_{i=1}^{n} \alpha_i \le \left( \beta \right)` reads as `∑ᵢ₌₁ⁿ αᵢ ≤ (β)` while the file on disk
-- stays exactly what the author typed. Two decisions make this work, and both are deliberate:
--
--   1. WHAT to conceal comes from the PARSE TREE, not from patterns. A regex conceal has to guess
--      whether `\alpha` inside a `verbatim` body, a `%` comment or a listing is real; the parser
--      already knows, because the grammar does not put commands there at all. The honest cost of the
--      choice is the other direction: while an edit leaves the document momentarily unparseable, the
--      tree for that region is stale and the concealment there is briefly wrong or absent — a regex
--      would not care. That trade is worth it: a wrong conceal in a code listing is a lie about the
--      document, a flicker mid-keystroke is not.
--
--   2. WHEN to conceal is EVERY REDRAW, for the VISIBLE ROWS ONLY, with EPHEMERAL extmarks placed
--      from a decoration provider. The obvious design — walk the buffer on every change and store
--      real extmarks — makes a 2000-line document pay for 2000 lines on every keystroke and leaves
--      thousands of marks for the editor to shift on every insert. Ephemeral marks live exactly one
--      redraw, so the cost is bounded by the WINDOW, not by the file: scrolling a 2k-line maths
--      document costs the same as scrolling a 50-line one (measured; see the plugin's work log).
--
-- The maps are DATA (`lvim-tex.conceal.data`) merged with the user's `conceal.maps`, and the maths
-- gate is `lvim-tex.zone` — the same gate the insert-mode abbreviations use, so the two features can
-- never disagree about where a formula ends.
--
-- `conceallevel` and `concealcursor` are WINDOW options, and they are set with `scope = "local"` while
-- a TeX buffer is displayed. That is not a compromise but the mechanism Vim provides: a window
-- remembers a local option value PER BUFFER, so the value applies to this buffer in this window and
-- the user's own `conceallevel` everywhere else is never touched — the same seam an ftplugin uses.
--
---@module "lvim-tex.conceal"

local api = vim.api
local ts = vim.treesitter

local config = require("lvim-tex.config")
local data = require("lvim-tex.conceal.data")
local zone = require("lvim-tex.zone")

-- lvim-utils is a hard dependency of the ecosystem, but setup() must survive a broken install long
-- enough for `:checkhealth` to say so — the same stance lvim-tex's entry point takes. The fallback is
-- exact here and only here: every conceal map is a plain string-keyed table with no array in it, the
-- one case where a deep extend and the ecosystem's merge agree.
local ok_utils, utils = pcall(require, "lvim-utils.utils")

local M = {}

---@class LvimTexConcealEntry
---@field kind   "symbol"|"letters"|"style"|"ref"|"section"  which renderer draws it
---@field char   string?                     replacement character (symbol/ref/section); "" hides it
---@field letters table<string, string>?     base letter → precomposed glyph (letters)
---@field hl     string?                     highlight for the argument (style)
---@field math   boolean                     only conceal inside a maths zone
---@field group  string                      the config group it came from

---@class LvimTexConcealCache
---@field tick integer                                    the changedtick the rows were computed at
---@field from integer?                                   first cached row
---@field to   integer?                                   last cached row
---@field rows table<integer, LvimTexConcealMark[]>       marks by row, for the cached span only

---@class LvimTexConcealBuf
---@field on    boolean                                       conceal is active for this buffer
---@field saved table<integer, { level: integer, cursor: string }>  per-window options we replaced
---@field parser vim.treesitter.LanguageTree?                 cached latex parser for the buffer
---@field cache LvimTexConcealCache?                          memoised marks for the visible span

---@type integer?  namespace of the decoration provider AND of its ephemeral marks
local ns = nil

---@type integer?  the plugin's conceal augroup
local augroup = nil

---@type vim.treesitter.Query?  compiled from the ENABLED groups only — a disabled group costs nothing
local query = nil

---@type table<string, LvimTexConcealEntry>  every concealable command, one flat lookup
local commands = {}

---@type table<string, string>?  effective superscript map (nil = the scripts group is off)
local sup = nil

---@type table<string, string>?  effective subscript map
local sub = nil

---@type table<integer, LvimTexConcealBuf>  per-buffer state (conceal is a VIEW of a buffer, so it is
--- keyed by buffer — unlike build state, which is keyed by the project root)
local bufs = {}

---@type string?  the last paint error, surfaced by health instead of breaking a redraw
M.last_error = nil

-- ---------------------------------------------------------------------------
-- The effective maps
-- ---------------------------------------------------------------------------

--- The shipped map for `group` with the user's `conceal.maps[group]` merged OVER a copy of it, so a
--- user entry for a command REPLACES the shipped one and every unmentioned command keeps its glyph.
---@param group string
---@return table
local function effective(group)
    local shipped = vim.deepcopy(data.maps[group] or {})
    local user = (config.conceal.maps or {})[group]
    if not user then
        return shipped
    end
    if ok_utils and utils and utils.merge then
        return utils.merge(shipped, user)
    end
    return vim.tbl_deep_extend("force", shipped, user)
end

--- Add one group's entries to the flat command lookup.
---@param group string
---@param kind "symbol"|"letters"|"style"|"ref"|"section"
---@return nil
local function load_group(group, kind)
    if not config.conceal.groups[group] then
        return
    end
    local math_only = (config.conceal.math_only or {})[group] == true
    for name, value in pairs(effective(group)) do
        if type(value) == "table" then
            -- A letter table: `\hat{a}` → â, `\mathbb{R}` → ℝ. Valid for `accents` and for the maths
            -- alphabets in `styles`, which is why the shape decides the renderer, not the group.
            commands[name] = { kind = "letters", letters = value, math = math_only, group = group }
        elseif kind == "style" then
            commands[name] = { kind = "style", hl = value, math = math_only, group = group }
        else
            commands[name] = { kind = kind, char = value, math = math_only, group = group }
        end
    end
end

-- The query is assembled from the ENABLED groups: a group that is off contributes no pattern, so its
-- nodes are never even visited. `(section)` in particular spans everything down to the next heading,
-- so leaving it out when the group is off is worth more than it looks.
---@type table<string, string>
local PATTERNS = {
    command = "(generic_command) @command",
    script = "[(superscript) (subscript)] @script",
    delimiter = "(math_delimiter) @delimiter",
    reference = table.concat({
        "[",
        "(label_reference)",
        "(label_reference_range)",
        "(citation)",
        "(glossary_entry_reference)",
        "(acronym_reference)",
        "] @reference",
    }, " "),
    section = table.concat({
        "[",
        "(part)",
        "(chapter)",
        "(section)",
        "(subsection)",
        "(subsubsection)",
        "(paragraph)",
        "(subparagraph)",
        "] @section",
    }, " "),
}

--- Rebuild the effective maps and the query from the live config. Called by `setup()`, by every group
--- toggle, and by `:LvimTex reload` — everything that can change what `conceal.maps`, `conceal.groups`
--- or `conceal.math_only` say.
---@return nil
function M.refresh()
    -- The memoised marks were computed against the OLD maps; the buffer has not changed, so nothing
    -- else would ever invalidate them.
    for _, st in pairs(bufs) do
        st.cache = nil
    end
    commands = {}
    load_group("math_symbols", "symbol")
    load_group("delimiters", "symbol")
    load_group("accents", "letters")
    load_group("styles", "style")
    load_group("refs", "ref")
    load_group("sections", "section")

    local groups = config.conceal.groups
    if groups.scripts then
        local map = effective("scripts")
        sup, sub = map.superscript, map.subscript
    else
        sup, sub = nil, nil
    end

    local parts = {}
    if groups.math_symbols or groups.delimiters or groups.accents or groups.styles then
        parts[#parts + 1] = PATTERNS.command
    end
    if groups.delimiters then
        parts[#parts + 1] = PATTERNS.delimiter
    end
    if groups.scripts then
        parts[#parts + 1] = PATTERNS.script
    end
    if groups.refs then
        parts[#parts + 1] = PATTERNS.reference
    end
    if groups.sections then
        parts[#parts + 1] = PATTERNS.section
    end

    query = nil
    if #parts > 0 then
        -- A grammar older than the node types above would fail to compile; that is a reason to
        -- conceal nothing and say so in health, never to break a redraw.
        local ok, compiled = pcall(ts.query.parse, "latex", table.concat(parts, "\n"))
        if ok then
            query = compiled
        else
            M.last_error = tostring(compiled)
        end
    end
end

-- ---------------------------------------------------------------------------
-- Painting one visible range
-- ---------------------------------------------------------------------------

---@class LvimTexConcealMark
---@field row     integer   0-based row
---@field col     integer   0-based start byte
---@field end_row integer   0-based end row (equal to `row` for every conceal)
---@field end_col integer   0-based end byte, exclusive
---@field conceal string?   replacement character ("" hides the range)
---@field hl      string?   highlight group (a `styles` argument)

---@class LvimTexConcealCtx
---@field buf   integer
---@field lines table<integer, string|false>                 line cache for THIS paint pass
---@field emit  fun(buf: integer, mark: LvimTexConcealMark)  where a produced mark goes

--- The text of `row`, fetched at most once per paint pass. Node text is read out of these lines
--- rather than with `get_node_text`, which would be one API call per node.
---@param ctx LvimTexConcealCtx
---@param row integer  0-based
---@return string?
local function line_at(ctx, row)
    local cached = ctx.lines[row]
    if cached == nil then
        cached = api.nvim_buf_get_lines(ctx.buf, row, row + 1, false)[1] or false
        ctx.lines[row] = cached
    end
    return cached or nil
end

--- Conceal one SINGLE-ROW byte range with `char` ("" hides it entirely).
---@param ctx LvimTexConcealCtx
---@param row integer
---@param col integer      0-based start byte
---@param end_col integer  0-based end byte (exclusive)
---@param char string
---@return nil
local function conceal(ctx, row, col, end_col, char)
    if end_col <= col then
        return
    end
    ctx.emit(ctx.buf, { row = row, col = col, end_row = row, end_col = end_col, conceal = char })
end

--- Highlight a range (may span rows) — how a `styles` entry renders emphasis once its wrapper is gone.
---@param ctx LvimTexConcealCtx
---@param sr integer
---@param sc integer
---@param er integer
---@param ec integer
---@param hl string
---@return nil
local function highlight(ctx, sr, sc, er, ec, hl)
    if er < sr or (er == sr and ec <= sc) then
        return
    end
    ctx.emit(ctx.buf, { row = sr, col = sc, end_row = er, end_col = ec, hl = hl })
end

--- The node's text, when it lies on ONE row (everything concealable does).
---@param ctx LvimTexConcealCtx
---@param node TSNode
---@return string? text
---@return integer? row      0-based
---@return integer? col      0-based start byte
---@return integer? end_col  0-based end byte, exclusive
local function one_row_text(ctx, node)
    local sr, sc, er, ec = node:range()
    if sr ~= er then
        return nil
    end
    local line = line_at(ctx, sr)
    if not line then
        return nil
    end
    return line:sub(sc + 1, ec), sr, sc, ec
end

--- Hide the `{` and `}` of a group node, leaving its contents on screen.
---@param ctx LvimTexConcealCtx
---@param group TSNode
---@return nil
local function hide_braces(ctx, group)
    local count = group:child_count()
    if count < 2 then
        return
    end
    for _, child in ipairs({ group:child(0), group:child(count - 1) }) do
        if child then
            local sr, sc, er, ec = child:range()
            if sr == er and ec - sc == 1 then
                local line = line_at(ctx, sr)
                local ch = line and line:sub(sc + 1, ec)
                if ch == "{" or ch == "}" then
                    conceal(ctx, sr, sc, ec, "")
                end
            end
        end
    end
end

--- The first `curly_group` DIRECT child of `node`, and how many there are — a command with two groups
--- (`\frac{a}{b}`) is not an accent or a style however its name looks.
---@param node TSNode
---@return TSNode?, integer
local function single_group(node)
    local first, count = nil, 0
    for child in node:iter_children() do
        if child:type() == "curly_group" then
            count = count + 1
            first = first or child
        end
    end
    return first, count
end

--- `\hat{a}` → â, `\mathbb{R}` → ℝ, and the brace-less text form `\"o` → ö.
---@param ctx LvimTexConcealCtx
---@param node TSNode        the whole command
---@param name TSNode        its command_name
---@param entry LvimTexConcealEntry
---@return nil
local function place_letters(ctx, node, name, entry)
    local group, count = single_group(node)
    if group then
        if count > 1 then
            return
        end
        local nsr, nsc, ner, nec = node:range()
        local inner = one_row_text(ctx, group)
        if not inner or nsr ~= ner then
            return
        end
        -- The whole `\cmd{x}` becomes ONE glyph, so the argument has to be exactly one character.
        local letter = inner:sub(2, #inner - 1)
        local glyph = #letter == 1 and entry.letters[letter] or nil
        if glyph then
            conceal(ctx, nsr, nsc, nec, glyph)
        end
        return
    end
    -- No braces: the accent applies to the character that follows it directly (`\~n`).
    local _, sr, sc, ec = one_row_text(ctx, name)
    if not sr or not ec then
        return
    end
    local line = line_at(ctx, sr)
    local letter = line and line:sub(ec + 1, ec + 1) or ""
    local glyph = entry.letters[letter]
    if glyph and sc then
        conceal(ctx, sr, sc, ec + 1, glyph)
    end
end

--- `\textbf{loud}` → `loud`, painted with the entry's highlight: conceal can replace a range with one
--- character but cannot make text bold, so the wrapper goes and the argument is highlighted instead.
---@param ctx LvimTexConcealCtx
---@param node TSNode
---@param name TSNode
---@param entry LvimTexConcealEntry
---@return nil
local function place_style(ctx, node, name, entry)
    local group = single_group(node)
    if not group then
        return
    end
    local nsr, nsc = name:range()
    local gsr, gsc, ger, gec = group:range()
    if nsr ~= gsr then
        return
    end
    -- `\textbf{` in one go, then the closing brace wherever it landed.
    conceal(ctx, nsr, nsc, gsc + 1, "")
    local close = group:child(group:child_count() - 1)
    if close then
        local csr, csc, cer, cec = close:range()
        if csr == cer and cec - csc == 1 then
            conceal(ctx, csr, csc, cec, "")
        end
    end
    if entry.hl then
        highlight(ctx, gsr, gsc + 1, ger, gec - 1, entry.hl)
    end
end

--- A reference or a heading: the command becomes one glyph and its braces disappear, so the KEY (or
--- the title) is all that is left on screen.
---@param ctx LvimTexConcealCtx
---@param cmd TSNode         the command token
---@param groups TSNode[]    the argument groups whose braces go
---@param char string
---@return nil
local function place_wrapper(ctx, cmd, groups, char)
    local _, sr, sc, ec = one_row_text(ctx, cmd)
    if not sr or not sc or not ec then
        return
    end
    conceal(ctx, sr, sc, ec, char)
    for _, group in ipairs(groups) do
        hide_braces(ctx, group)
    end
end

--- One `generic_command`: the map decides which renderer it gets, and a command that is in no map
--- costs exactly one hash lookup.
---@param ctx LvimTexConcealCtx
---@param node TSNode
---@return nil
local function place_command(ctx, node)
    local name = node:named_child(0)
    if not name or name:type() ~= "command_name" then
        return
    end
    local text, sr, sc, ec = one_row_text(ctx, name)
    if not text or not sr or not sc or not ec then
        return
    end
    local entry = commands[text]
    if not entry then
        return
    end
    if entry.math and not zone.in_math_node(node) then
        return
    end
    if entry.kind == "symbol" then
        conceal(ctx, sr, sc, ec, entry.char)
    elseif entry.kind == "letters" then
        place_letters(ctx, node, name, entry)
    elseif entry.kind == "style" then
        place_style(ctx, node, name, entry)
    else
        -- A ref/section command the grammar did not give a node type of its own.
        local groups = {}
        for child in node:iter_children() do
            if child:type():sub(1, 11) == "curly_group" then
                groups[#groups + 1] = child
            end
        end
        place_wrapper(ctx, name, groups, entry.char)
    end
end

--- `x^{2n}` → `x²ⁿ`. All or nothing: a script is concealed only when EVERY character of it has a
--- Unicode script form, because half-lowered text reads worse than the source did.
---@param ctx LvimTexConcealCtx
---@param node TSNode  a superscript or subscript node
---@return nil
local function place_script(ctx, node)
    local map = node:type() == "superscript" and sup or sub
    if not map then
        return
    end
    if (config.conceal.math_only or {}).scripts and not zone.in_math_node(node) then
        return
    end
    local marker = node:child(0)
    local content = node:child(1)
    if not marker or not content then
        return
    end
    local msr, msc, mer, mec = marker:range()
    local csr, csc, cer, cec = content:range()
    if msr ~= mer or csr ~= cer or msr ~= csr then
        return
    end
    local line = line_at(ctx, csr)
    if not line then
        return
    end
    local braced = content:type() == "curly_group"
    local from = braced and csc + 1 or csc
    local to = braced and cec - 1 or cec
    if to <= from then
        return
    end
    local text = line:sub(from + 1, to)
    local glyphs = {}
    for i = 1, #text do
        local glyph = map[text:sub(i, i)]
        if not glyph then
            return
        end
        glyphs[i] = glyph
    end
    -- `^{` is hidden as ONE range rather than two: fewer marks is less work every single redraw, and
    -- two adjacent ranges concealed to nothing are indistinguishable from one.
    conceal(ctx, msr, msc, braced and csc + 1 or mec, "")
    if braced then
        conceal(ctx, csr, cec - 1, cec, "")
    end
    for i = 1, #glyphs do
        conceal(ctx, csr, from + i - 1, from + i, glyphs[i])
    end
end

-- The four parts of a `\left…\right` pair, each looked up in the same command map: that is why
-- `\left\langle x \right\rangle` collapses to `⟨x⟩` — the sizing commands map to "" and the named
-- delimiters to their glyphs, with no rule that knows about either.
---@type string[]
local DELIM_FIELDS = { "left_command", "left_delimiter", "right_command", "right_delimiter" }

--- A `\left…\right` (or `\bigl…\bigr`) pair.
---@param ctx LvimTexConcealCtx
---@param node TSNode
---@return nil
local function place_delimiter(ctx, node)
    for _, field in ipairs(DELIM_FIELDS) do
        local part = node:field(field)[1]
        if part then
            local text, sr, sc, ec = one_row_text(ctx, part)
            local entry = text and commands[text]
            if entry and entry.kind == "symbol" and sr and sc and ec then
                conceal(ctx, sr, sc, ec, entry.char)
            end
        end
    end
end

--- A `\ref{…}` / `\cite{…}` / `\gls{…}` node: the command token, then every argument group.
---@param ctx LvimTexConcealCtx
---@param node TSNode
---@return nil
local function place_reference(ctx, node)
    local cmd = node:child(0)
    if not cmd then
        return
    end
    local text = one_row_text(ctx, cmd)
    local entry = text and commands[text]
    if not entry or entry.kind ~= "ref" then
        return
    end
    local groups = {}
    for child in node:iter_children() do
        if child:type():sub(1, 11) == "curly_group" then
            groups[#groups + 1] = child
        end
    end
    place_wrapper(ctx, cmd, groups, entry.char)
end

--- A heading. Its node runs to the next heading of the same level, so only the `command` and `text`
--- FIELDS are touched — everything else inside it is the section's body.
---@param ctx LvimTexConcealCtx
---@param node TSNode
---@param toprow integer
---@param botrow integer
---@return nil
local function place_section(ctx, node, toprow, botrow)
    local cmd = node:field("command")[1]
    if not cmd then
        return
    end
    local row = cmd:range()
    -- A heading far above the viewport still intersects it (its body does), and its own row is the
    -- only thing this draws.
    if row < toprow or row > botrow then
        return
    end
    local text = one_row_text(ctx, cmd)
    local entry = text and commands[text]
    if not entry or entry.kind ~= "section" then
        return
    end
    place_wrapper(ctx, cmd, node:field("text"), entry.char)
end

--- Produce every conceal mark the rows `toprow..botrow` of `buf` need, handing each to `emit`.
---
--- The sink is a parameter so the SAME renderer serves both callers: the decoration provider emits
--- ephemeral extmarks (which last one redraw, so nothing has to be cleaned up and nothing outside the
--- window is ever built), while `M.marks()` collects them as data for health, debugging and the proofs
--- — a headless Neovim never redraws, so there is no other way to assert what a line would look like.
---@param buf integer
---@param toprow integer  0-based first visible row
---@param botrow integer  0-based last visible row
---@param emit fun(buf: integer, mark: LvimTexConcealMark)
---@return nil
local function paint(buf, toprow, botrow, emit)
    if not query then
        return
    end
    local st = bufs[buf]
    local parser = st and st.parser
    if not parser then
        parser = ts.get_parser(buf, "latex", { error = false })
        if not parser then
            return
        end
        if st then
            st.parser = parser
        end
    end
    -- Parse the VISIBLE range only. When the tree is already valid for it — the normal case, since
    -- the highlighter has just parsed it — this returns immediately (measured: 0.015 ms per screen).
    local trees = parser:parse({ toprow, botrow })
    if not trees then
        return
    end

    -- What has to be COMPUTED is not what has to be DRAWN. Marks last one redraw and must be handed
    -- over every time, but the marks a row NEEDS only change when the buffer does — so they are
    -- memoised per row against the changedtick, and a redraw that shows rows already computed (a
    -- cursor move, a one-line scroll, anything that repaints an unchanged screen) does no work at all
    -- beyond placing them. The cache holds the CURRENT span only, so it cannot grow with the file.
    local cache = st and st.cache
    local tick = api.nvim_buf_get_changedtick(buf)
    if not cache or cache.tick ~= tick then
        cache = { tick = tick, rows = {} }
        if st then
            st.cache = cache
        end
    end

    ---@type LvimTexConcealCtx
    local ctx = { buf = buf, lines = {}, emit = emit }
    local captures = query.captures

    --- Compute rows `first..last` into the cache, dropping anything a neighbouring row owns.
    ---@param first integer
    ---@param last integer
    ---@return nil
    local function compute(first, last)
        for row = first, last do
            cache.rows[row] = {}
        end
        ctx.emit = function(_, mark)
            local bucket = cache.rows[mark.row]
            if bucket then
                bucket[#bucket + 1] = mark
            end
        end
        for _, tree in pairs(trees) do
            for id, node in query:iter_captures(tree:root(), buf, first, last + 1) do
                local capture = captures[id]
                if capture == "command" then
                    place_command(ctx, node)
                elseif capture == "script" then
                    place_script(ctx, node)
                elseif capture == "delimiter" then
                    place_delimiter(ctx, node)
                elseif capture == "reference" then
                    place_reference(ctx, node)
                elseif capture == "section" then
                    place_section(ctx, node, first, last)
                end
            end
        end
    end

    if not cache.from or toprow > cache.to + 1 or botrow < cache.from - 1 then
        -- A jump: nothing of the old span is reachable from the new one.
        cache.rows = {}
        compute(toprow, botrow)
    else
        if toprow < cache.from then
            compute(toprow, cache.from - 1)
        end
        if botrow > cache.to then
            compute(cache.to + 1, botrow)
        end
        for row = cache.from, toprow - 1 do
            cache.rows[row] = nil
        end
        for row = botrow + 1, cache.to do
            cache.rows[row] = nil
        end
    end
    cache.from, cache.to = toprow, botrow

    for row = toprow, botrow do
        local marks = cache.rows[row]
        if marks then
            for i = 1, #marks do
                emit(buf, marks[i])
            end
        end
    end
end

--- The decoration provider's sink: one EPHEMERAL extmark, valid for this redraw only.
---@param buf integer
---@param mark LvimTexConcealMark
---@return nil
local function place(buf, mark)
    api.nvim_buf_set_extmark(buf, ns, mark.row, mark.col, {
        end_row = mark.end_row,
        end_col = mark.end_col,
        conceal = mark.conceal,
        hl_group = mark.hl,
        hl_mode = mark.hl and "combine" or nil,
        ephemeral = true,
    })
end

-- ---------------------------------------------------------------------------
-- The window options
-- ---------------------------------------------------------------------------

--- Every window currently displaying `buf`.
---@param buf integer
---@return integer[]
local function windows_of(buf)
    local out = {}
    for _, win in ipairs(api.nvim_list_wins()) do
        if api.nvim_win_get_buf(win) == buf then
            out[#out + 1] = win
        end
    end
    return out
end

--- Give `win` the conceal options while it shows `buf`, remembering what was there first.
---
--- `scope = "local"` is the whole point: Vim keeps a window's local option value PER BUFFER, so this
--- is scoped to this buffer in this window and the user's `conceallevel` in every other buffer — and
--- in this window once it shows something else — is untouched.
---@param win integer
---@param st LvimTexConcealBuf
---@return nil
local function apply_options(win, st)
    if not st.saved[win] then
        st.saved[win] = {
            level = api.nvim_get_option_value("conceallevel", { scope = "local", win = win }),
            cursor = api.nvim_get_option_value("concealcursor", { scope = "local", win = win }),
        }
    end
    api.nvim_set_option_value("conceallevel", config.conceal.level, { scope = "local", win = win })
    api.nvim_set_option_value("concealcursor", config.conceal.cursor, { scope = "local", win = win })
end

--- Put back what `apply_options` replaced.
---@param win integer
---@param st LvimTexConcealBuf
---@return nil
local function restore_options(win, st)
    local saved = st.saved[win]
    if not saved or not api.nvim_win_is_valid(win) then
        st.saved[win] = nil
        return
    end
    api.nvim_set_option_value("conceallevel", saved.level, { scope = "local", win = win })
    api.nvim_set_option_value("concealcursor", saved.cursor, { scope = "local", win = win })
    st.saved[win] = nil
end

-- ---------------------------------------------------------------------------
-- Public surface
-- ---------------------------------------------------------------------------

--- Resolve a buffer argument the way every Neovim API does (nil/0 = current).
---@param buf integer?
---@return integer
local function resolve_buf(buf)
    if buf == nil or buf == 0 then
        return api.nvim_get_current_buf()
    end
    return buf
end

--- Notify, gated by `config.notify` — the same voice as the rest of the plugin.
---@param msg string
---@return nil
local function notify(msg)
    if config.notify then
        vim.notify(("lvim-tex: %s %s"):format(config.icons.math, msg), vim.log.levels.INFO)
    end
end

--- Start concealing in `buf` (and in every window showing it).
---@param buf integer?
---@return nil
function M.enable(buf)
    buf = resolve_buf(buf)
    M.attach(buf)
    local st = bufs[buf]
    if not st or st.on then
        return
    end
    st.on = true
    for _, win in ipairs(windows_of(buf)) do
        apply_options(win, st)
    end
end

--- Stop concealing in `buf`, restoring the conceal options each window had before.
---@param buf integer?
---@return nil
function M.disable(buf)
    buf = resolve_buf(buf)
    local st = bufs[buf]
    if not st or not st.on then
        return
    end
    st.on = false
    for _, win in ipairs(vim.tbl_keys(st.saved)) do
        restore_options(win, st)
    end
end

--- Is conceal active in `buf`?
---@param buf integer?
---@return boolean
function M.is_enabled(buf)
    local st = bufs[resolve_buf(buf)]
    return st ~= nil and st.on
end

--- `:LvimTex conceal` — with no argument, turn conceal on or off for this buffer; with a GROUP name
--- (`math_symbols`, `scripts`, `delimiters`, `accents`, `styles`, `refs`, `sections`), turn that group
--- on or off for every TeX buffer, since a group is a document-wide preference and not a per-file one.
---@param buf integer?
---@param group string?
---@return nil
function M.toggle(buf, group)
    buf = resolve_buf(buf)
    if group and group ~= "" then
        if config.conceal.groups[group] == nil then
            local names = vim.tbl_keys(config.conceal.groups)
            table.sort(names)
            notify(("unknown conceal group %q (%s)"):format(group, table.concat(names, "|")))
            return
        end
        config.conceal.groups[group] = not config.conceal.groups[group]
        M.refresh()
        vim.cmd.redraw({ bang = true })
        notify(("conceal %s: %s"):format(group, config.conceal.groups[group] and "on" or "off"))
        return
    end
    if M.is_enabled(buf) then
        M.disable(buf)
    else
        M.enable(buf)
    end
    notify(("conceal %s"):format(M.is_enabled(buf) and "on" or "off"))
end

--- Track `buf` (idempotent), and turn conceal on when `conceal.enabled` says so.
---@param buf integer
---@return nil
function M.attach(buf)
    if bufs[buf] then
        return
    end
    bufs[buf] = { on = false, saved = {} }
    if config.conceal.enabled then
        M.enable(buf)
    end
end

--- What conceal WOULD draw over the rows `first..last` of `buf`, as data.
---
--- The same renderer the decoration provider runs, with the marks collected instead of drawn — so
--- "why is this line concealed like that" has an answer that does not involve staring at the screen,
--- and a headless proof can assert the rendering of a document it never displays.
---@param buf integer?   buffer (nil/0 = current)
---@param first integer  0-based first row
---@param last integer   0-based last row (inclusive)
---@return LvimTexConcealMark[]
function M.marks(buf, first, last)
    buf = resolve_buf(buf)
    local out = {}
    paint(buf, first, last, function(_, mark)
        out[#out + 1] = mark
    end)
    return out
end

--- `buf`'s row `row` as conceal makes it LOOK: the source with every concealed range replaced by its
--- glyph. What the eye gets from a screenshot, in a string a proof can compare.
---@param buf integer?
---@param row integer  0-based
---@return string
function M.render(buf, row)
    buf = resolve_buf(buf)
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local marks = M.marks(buf, row, row)
    table.sort(marks, function(a, b)
        return a.col < b.col
    end)
    local out, at = {}, 0
    for _, mark in ipairs(marks) do
        if mark.conceal and mark.row == row and mark.col >= at then
            out[#out + 1] = line:sub(at + 1, mark.col)
            out[#out + 1] = mark.conceal
            at = mark.end_col
        end
    end
    out[#out + 1] = line:sub(at + 1)
    return table.concat(out)
end

--- What conceal is doing right now — `:checkhealth lvim-tex` and `:LvimTex info` read this rather
--- than reaching into the module.
---@param buf integer?
---@return { enabled: boolean, level: integer, cursor: string, groups: table<string, boolean>, commands: integer, parser: boolean, error: string? }
function M.status(buf)
    buf = resolve_buf(buf)
    local count = 0
    for _ in pairs(commands) do
        count = count + 1
    end
    return {
        enabled = M.is_enabled(buf),
        level = config.conceal.level,
        cursor = config.conceal.cursor,
        groups = vim.deepcopy(config.conceal.groups),
        commands = count,
        parser = #api.nvim_get_runtime_file("parser/latex.so", false) > 0,
        error = M.last_error,
    }
end

--- Install the decoration provider and the autocmds that keep the window options right.
---
--- Self-contained on purpose: conceal owns a WINDOW-scoped effect, and a window event (a split, a
--- buffer shown in a second window) is not something a buffer-attach hook can express — so the
--- feature registers its own autocmds, exactly as a panel registers its own filetype with the shared
--- cursor module.
---@return nil
function M.setup()
    M.refresh()
    if ns then
        return
    end
    ns = api.nvim_create_namespace("lvim-tex.conceal")
    augroup = api.nvim_create_augroup("LvimTexConceal", { clear = true })

    api.nvim_set_decoration_provider(ns, {
        on_win = function(_, _, buf, toprow, botrow)
            local st = bufs[buf]
            if not st or not st.on then
                return false
            end
            -- A failing map or a grammar change must never wedge a redraw; health reports it.
            local ok, err = pcall(paint, buf, toprow, botrow, place)
            if not ok then
                M.last_error = tostring(err)
            end
            return false
        end,
    })

    api.nvim_create_autocmd("FileType", {
        group = augroup,
        pattern = config.filetypes,
        desc = "lvim-tex: track a TeX buffer for conceal",
        callback = function(args)
            M.attach(args.buf)
        end,
    })

    -- A buffer shown in a NEW window needs that window's conceal options too.
    api.nvim_create_autocmd("BufWinEnter", {
        group = augroup,
        desc = "lvim-tex: apply the conceal options to a window showing a TeX buffer",
        callback = function(args)
            local st = bufs[args.buf]
            if st and st.on then
                apply_options(api.nvim_get_current_win(), st)
            end
        end,
    })

    api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
        group = augroup,
        desc = "lvim-tex: forget a buffer's conceal state",
        callback = function(args)
            bufs[args.buf] = nil
        end,
    })

    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) and vim.tbl_contains(config.filetypes, vim.bo[buf].filetype) then
            M.attach(buf)
        end
    end
end

return M
