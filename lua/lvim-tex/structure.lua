-- lvim-tex: the SHAPE of the document — its sections, labels, TODOs and includes, in the order the
-- reader meets them, across every file the root pulls in.
--
-- This is the model the TOC panel renders, the label/citation pickers list, and the follow-the-cursor
-- highlight resolves against. Three things about it are deliberate:
--
--   • THE DOCUMENT IS FLAT, THE TREE IS DERIVED. A `\section` in a chapter file is a child of the
--     `\chapter` written in the ROOT — the two live in different files, so no per-file parse tree can
--     express the nesting. So each file is scanned into an ordered list of entries carrying a LEVEL,
--     an `\input` splices the included file's list in at its own position, and the hierarchy is
--     rebuilt from the levels afterwards. That is also exactly how LaTeX itself reads the document.
--
--   • THE PARSE IS CACHED PER FILE, KEYED ON A CHANGE STAMP (the M9 row). A refresh re-parses only
--     the files that actually changed — the buffer being edited — and reuses the rest; a project's
--     structure is therefore re-derived in the time it takes to parse ONE file, not the whole tree.
--     The stamp is the loaded buffer's changedtick while it is modified, else the file's mtime+size,
--     so an UNSAVED edit invalidates too. No cross-session (on-disk) cache: see the module's note in
--     `findings.md` — the measured cold parse of a whole project is a fraction of the panel's own
--     open cost, so persisting it would buy nothing and could go stale.
--
--   • SECTION NUMBERS ARE COMPUTED, NOT READ. The `.aux` holds the real ones but only after a build;
--     the TOC has to be right in a document that has never compiled. Counters are run over the flat
--     list exactly as LaTeX runs them (a starred section takes no number and resets nothing).
--
---@module "lvim-tex.structure"

local config = require("lvim-tex.config")
local nav = require("lvim-tex.nav")
local root_mod = require("lvim-tex.root")

local fs = vim.fs

local M = {}

--- Sectioning command → its depth. The numbers are the levels LaTeX itself nests by; a document class
--- simply starts further down (an article has no `\chapter`), which the numbering handles by taking
--- the shallowest level actually present as the top.
---@type table<string, integer>
M.SECTION_LEVEL = {
    part = 1,
    chapter = 2,
    section = 3,
    subsection = 4,
    subsubsection = 5,
    paragraph = 6,
    subparagraph = 7,
}

--- The deepest sectioning level there is (`1`-`7` fold-depth keys map onto it).
M.MAX_LEVEL = 7

---@class LvimTexEntry
---@field kind    "section"|"include"|"label"|"todo"  what the row IS
---@field level   integer   sectioning depth (1-7); non-section entries carry the depth they were found at
---@field title   string    the display text (section title, include path, label key, TODO text)
---@field file    string    absolute path of the file the entry is written in
---@field lnum    integer   1-based line
---@field col     integer   1-based column
---@field star    boolean?  a starred section (`\section*`) — no number, no counter step
---@field label   string?   section: the `\label` attached to it; label entry: the key itself
---@field number  string?   section: the computed number ("2.1.3"), absent for starred ones
---@field target  string?   include: the resolved absolute path (nil when it does not exist)
---@field spec    string?   include: the argument as written
---@field include string?   include: the resource kind ("tex"|"graphics"|"bib"|…, see nav.KIND)
---@field keyword string?   todo: the keyword that matched (TODO, FIXME, …)

--- Per-file scan cache: path → { stamp, entries }.
---@type table<string, { stamp: string, entries: LvimTexEntry[] }>
local cache = {}

--- Cache statistics for the proof harness and `:LvimTex info` — parses avoided vs performed.
---@type { hits: integer, misses: integer }
M.stats = { hits = 0, misses = 0 }

--- The text of a `curly_group`-ish node with its braces stripped and its whitespace collapsed, which
--- is what a title reads as on one panel row.
---@param node TSNode?
---@param src string
---@return string
local function group_text(node, src)
    if not node then
        return ""
    end
    local text = vim.treesitter.get_node_text(node, src)
    text = text:gsub("^%s*{", ""):gsub("}%s*$", "")
    return (vim.trim(text:gsub("%s+", " ")))
end

--- The first child of `node` whose type is in `types`.
---@param node TSNode
---@param types table<string, boolean>
---@return TSNode?
local function first_child(node, types)
    for child in node:iter_children() do
        if types[child:type()] then
            return child
        end
    end
    return nil
end

---@type table<string, boolean>
local TITLE_GROUP = { curly_group = true, curly_group_text = true }
---@type table<string, boolean>
local LABEL_GROUP = { curly_group_label = true, curly_group_label_list = true }

--- Include node types whose target lives in the TeX DISTRIBUTION rather than in the project — never a
--- structure row.
---@type table<string, boolean>
local DISTRIBUTION = { class_include = true, package_include = true, bibstyle_include = true }

--- Scan ONE file into its ordered entry list (uncached — `M.entries` is the caching front door).
---@param path string
---@return LvimTexEntry[]
local function scan(path)
    local out = {}
    if not pcall(vim.treesitter.language.add, "latex") then
        return out
    end
    local src = nav.read(path)
    if not src then
        return out
    end
    local ok, parser = pcall(vim.treesitter.get_string_parser, src, "latex")
    if not ok or not parser then
        return out
    end
    local tree = parser:parse()[1]
    if not tree then
        return out
    end

    local todo_pattern = "^%s*%%+%s*([%u]+)%s*:?%s*(.*)$"
    local keywords = {}
    for _, word in ipairs(config.outline.todo_keywords or {}) do
        keywords[word:upper()] = true
    end

    --- Emit one entry.
    ---@param entry LvimTexEntry
    local function emit(entry)
        out[#out + 1] = entry
    end

    --- Walk the tree in source order, emitting entries. `level` is the sectioning depth the walk is
    --- currently inside, which is what a non-section entry (a label, a TODO, an include) inherits.
    ---@param node TSNode
    ---@param level integer
    local function walk(node, level)
        local kind = node:type()
        local section_level = M.SECTION_LEVEL[kind]

        if section_level then
            local command = node:child(0)
            local name = command and vim.treesitter.get_node_text(command, src) or ""
            local row, col = node:range()
            emit({
                kind = "section",
                level = section_level,
                title = group_text(first_child(node, TITLE_GROUP), src),
                file = path,
                lnum = row + 1,
                col = col + 1,
                star = name:sub(-1) == "*",
            })
            level = section_level
        elseif kind == "label_definition" then
            local row, col = node:range()
            emit({
                kind = "label",
                level = level,
                title = group_text(first_child(node, LABEL_GROUP), src),
                label = group_text(first_child(node, LABEL_GROUP), src),
                file = path,
                lnum = row + 1,
                col = col + 1,
            })
        elseif nav.KIND[kind] and not DISTRIBUTION[kind] then
            -- `\documentclass`, `\usepackage` and `\bibliographystyle` ARE includes to the grammar, but
            -- they name distribution files, not places the reader navigates to — so they never become
            -- TOC rows (`gf` still resolves every one of them).
            local include_kind = nav.KIND[kind]
            local specs = {}
            ---@param n TSNode
            local function leaves(n)
                for child in n:iter_children() do
                    local t = child:type()
                    if t == "path" or t == "glob_pattern" then
                        specs[#specs + 1] = vim.treesitter.get_node_text(child, src)
                    else
                        leaves(child)
                    end
                end
            end
            leaves(node)
            local spec = specs[1]
            if kind == "import_include" and specs[2] then
                spec = specs[1]:gsub("/$", "") .. "/" .. specs[2]
            end
            if spec and spec ~= "" then
                local row, col = node:range()
                for _, one in ipairs(vim.split(spec, ",", { plain = true })) do
                    one = vim.trim(one)
                    if one ~= "" then
                        local target = nav.resolve(one, include_kind, nav.search_dirs(include_kind, path, nil))
                        emit({
                            kind = "include",
                            level = level,
                            title = one,
                            file = path,
                            lnum = row + 1,
                            col = col + 1,
                            spec = one,
                            include = include_kind,
                            target = target,
                        })
                    end
                end
            end
            return -- an include node holds nothing else the TOC wants
        elseif kind == "line_comment" then
            local text = vim.treesitter.get_node_text(node, src)
            local word, rest = text:match(todo_pattern)
            if word and keywords[word] then
                local row, col = node:range()
                emit({
                    kind = "todo",
                    level = level,
                    title = vim.trim(rest) ~= "" and vim.trim(rest) or word,
                    keyword = word,
                    file = path,
                    lnum = row + 1,
                    col = col + 1,
                })
            end
            return
        end

        for child in node:iter_children() do
            walk(child, level)
        end
    end

    walk(tree:root(), 0)

    -- A `\label` written on the same line as its section belongs TO that section (it is how a section
    -- is cross-referenced), so it rides along as the section's own label instead of taking a row of
    -- its own. A label further down (a figure's, an equation's) stays an entry.
    local result = {}
    for _, entry in ipairs(out) do
        local previous = result[#result]
        if
            entry.kind == "label"
            and previous
            and previous.kind == "section"
            and previous.lnum == entry.lnum
            and not previous.label
        then
            previous.label = entry.label
        else
            result[#result + 1] = entry
        end
    end
    return result
end

--- One file's entries, from the cache when the file has not changed since it was parsed.
---@param path string
---@return LvimTexEntry[]
function M.entries(path)
    local stamp = nav.stamp(path)
    local hit = cache[path]
    if hit and hit.stamp == stamp then
        M.stats.hits = M.stats.hits + 1
        return hit.entries
    end
    M.stats.misses = M.stats.misses + 1
    local entries = scan(path)
    cache[path] = { stamp = stamp, entries = entries }
    return entries
end

--- Drop the cached parse of `path` (all files when nil). Only ever needed to force a re-parse — the
--- change stamp already invalidates on its own.
---@param path string?
---@return nil
function M.invalidate(path)
    if path then
        cache[path] = nil
    else
        cache = {}
    end
end

--- Roman numeral for `n` (parts are numbered in Roman, in every standard class).
---@param n integer
---@return string
local function roman(n)
    local pairs_ = {
        { 1000, "M" },
        { 900, "CM" },
        { 500, "D" },
        { 400, "CD" },
        { 100, "C" },
        { 90, "XC" },
        { 50, "L" },
        { 40, "XL" },
        { 10, "X" },
        { 9, "IX" },
        { 5, "V" },
        { 4, "IV" },
        { 1, "I" },
    }
    local out = {}
    for _, step in ipairs(pairs_) do
        while n >= step[1] do
            out[#out + 1] = step[2]
            n = n - step[1]
        end
    end
    return table.concat(out)
end

--- Run LaTeX's sectioning counters over a flat entry list, filling in `number`.
---
--- Two rules that a naive "join the counters" would get wrong, both taken from how the standard
--- classes actually count:
---   • `\part` is INDEPENDENT — Roman, and it neither prefixes nor resets the chapters under it
---     (chapter 3 stays chapter 3 in part II). So the dotted chain starts BELOW it.
---   • the chain's top is the shallowest level the document actually uses below `\part` (a book
---     starts at `\chapter`, an article at `\section`), so `1.2` reads the same in both.
--- A starred section takes no number and, as in LaTeX, does not advance any counter.
---@param entries LvimTexEntry[]
---@return nil
local function number(entries)
    local PART = M.SECTION_LEVEL.part
    local top = M.MAX_LEVEL + 1
    for _, entry in ipairs(entries) do
        if entry.kind == "section" and not entry.star and entry.level > PART and entry.level < top then
            top = entry.level
        end
    end
    local counters = {}
    for level = 1, M.MAX_LEVEL do
        counters[level] = 0
    end
    for _, entry in ipairs(entries) do
        if entry.kind == "section" and not entry.star then
            if entry.level == PART then
                counters[PART] = counters[PART] + 1
                entry.number = roman(counters[PART])
            elseif entry.level >= top then
                counters[entry.level] = counters[entry.level] + 1
                for deeper = entry.level + 1, M.MAX_LEVEL do
                    counters[deeper] = 0
                end
                local chain = {}
                for level = top, entry.level do
                    chain[#chain + 1] = tostring(counters[level])
                end
                entry.number = table.concat(chain, ".")
            end
        end
    end
end

--- The WHOLE document's entries, in reading order: the root's own, with every TeX include's entries
--- spliced in at the point the include is written. Cycle-guarded (a file that includes an ancestor
--- would otherwise recurse forever) and numbered.
---@param root string  the root document
---@return LvimTexEntry[]
function M.document(root)
    local out, seen = {}, {}

    ---@param path string
    local function splice(path)
        if seen[path] then
            return
        end
        seen[path] = true
        for _, cached in ipairs(M.entries(path)) do
            -- A COPY per document: the per-file cache is shared between projects (a subfile compiled
            -- standalone is its own root), and the numbering below writes into what it is handed.
            local entry = vim.tbl_extend("force", {}, cached) --[[@as LvimTexEntry]]
            -- Each file is scanned against its OWN directory; an include the file's own directory does
            -- not hold is re-resolved here with the root in hand, so a root-relative `\input` written
            -- inside a chapter resolves too.
            if entry.kind == "include" and not entry.target then
                local include_kind = entry.include or "tex"
                entry.target =
                    nav.resolve(entry.spec or entry.title, include_kind, nav.search_dirs(include_kind, path, root))
            end
            out[#out + 1] = entry
            if entry.kind == "include" and nav.RECURSIVE[entry.include or ""] and entry.target then
                splice(entry.target)
            end
        end
        seen[path] = nil -- a sibling may legitimately include the same file twice in sequence
    end

    splice(root)
    number(out)
    return out
end

--- The document's `\title{…}`, when it declares one — the natural name for the TOC panel.
---@param root string
---@return string?
function M.title(root)
    local src = nav.read(root)
    if not src then
        return nil
    end
    local title = src:match("\\title%s*(%b{})")
    if not title then
        return nil
    end
    title = vim.trim(title:sub(2, -2):gsub("%s+", " "))
    return title ~= "" and title or nil
end

--- Every `\label` in the project, with the section it sits under as context.
---@param root string
---@return { key: string, file: string, lnum: integer, col: integer, context: string }[]
function M.labels(root)
    local out, section = {}, nil
    for _, entry in ipairs(M.document(root)) do
        if entry.kind == "section" then
            section = entry
            if entry.label then
                out[#out + 1] = {
                    key = entry.label,
                    file = entry.file,
                    lnum = entry.lnum,
                    col = entry.col,
                    context = entry.title,
                }
            end
        elseif entry.kind == "label" then
            out[#out + 1] = {
                key = entry.title,
                file = entry.file,
                lnum = entry.lnum,
                col = entry.col,
                context = section and section.title or "",
            }
        end
    end
    return out
end

--- Every citation KEY used in the project, with the first place it is cited.
---@param root string
---@return table<string, { file: string, lnum: integer, col: integer, count: integer }>
function M.citations(root)
    local out = {}
    if not pcall(vim.treesitter.language.add, "latex") then
        return out
    end
    for _, record in ipairs(M.files(root)) do
        local path = record.path
        local src = record.kind == "tex" and nav.read(path) or nil
        local ok, parser = pcall(vim.treesitter.get_string_parser, src or "", "latex")
        local tree = (src and ok and parser) and parser:parse()[1] or nil
        if tree and src then
            ---@param node TSNode
            local function walk(node)
                if node:type() == "citation" then
                    local row, col = node:range()
                    local group = first_child(node, { curly_group_text_list = true })
                    local text = group and vim.treesitter.get_node_text(group, src):sub(2, -2) or ""
                    for _, key in ipairs(vim.split(text, ",", { plain = true })) do
                        key = vim.trim(key)
                        if key ~= "" then
                            local hit = out[key]
                            if hit then
                                hit.count = hit.count + 1
                            else
                                out[key] = { file = path, lnum = row + 1, col = col + 1, count = 1 }
                            end
                        end
                    end
                    return
                end
                for child in node:iter_children() do
                    walk(child)
                end
            end
            walk(tree:root())
        end
    end
    return out
end

--- Every entry defined in the project's bibliography files, read with the `bibtex` grammar (so a
--- multi-line entry, a comment or a `@string` cannot be mistaken for one).
---@param root string
---@return { key: string, type: string, file: string, lnum: integer, fields: table<string, string> }[]
function M.bib_entries(root)
    local out = {}
    if not pcall(vim.treesitter.language.add, "bibtex") then
        return out
    end
    for _, record in ipairs(M.files(root)) do
        local path = record.path
        if record.kind == "bib" then
            local src = nav.read(path)
            local ok, parser = pcall(vim.treesitter.get_string_parser, src or "", "bibtex")
            local tree = (ok and parser) and parser:parse()[1] or nil
            if tree and src then
                for node in tree:root():iter_children() do
                    if node:type() == "entry" then
                        local row = node:range()
                        local entry = { key = "", type = "", file = path, lnum = row + 1, fields = {} }
                        for child in node:iter_children() do
                            local kind = child:type()
                            if kind == "entry_type" then
                                entry.type = vim.treesitter.get_node_text(child, src):gsub("^@", ""):lower()
                            elseif kind == "key_brace" then
                                entry.key = vim.trim(vim.treesitter.get_node_text(child, src))
                            elseif kind == "field" then
                                local name = first_child(child, { identifier = true })
                                local value = first_child(child, { value = true })
                                if name then
                                    local field = vim.treesitter.get_node_text(name, src):lower()
                                    entry.fields[field] = group_text(value, src):gsub('^"(.*)"$', "%1")
                                end
                            end
                        end
                        if entry.key ~= "" then
                            out[#out + 1] = entry
                        end
                    end
                end
            end
        end
    end
    return out
end

--- The project's files, root first, as `{ path, kind }` records — every file the document actually
--- pulls in, each classified by what it is so a picker row can front the right glyph.
---
--- Built from the DOCUMENT's own include entries, not only from `root.graph`: the graph resolves with
--- the TeX extension list alone, so an extension-less `\includegraphics{plot}` is invisible to it,
--- while the structure scan resolves each include with the list for ITS kind (and through
--- `\graphicspath`). The graph is unioned in so a file it knows about — one the parser could not see
--- because latexmk's records named it — is not lost either.
---@param root string
---@return { path: string, kind: string }[]
function M.files(root)
    local out, seen = {}, {}
    ---@param path string
    ---@param kind string?
    local function add(path, kind)
        if not path or seen[path] then
            return
        end
        seen[path] = true
        if not kind then
            kind = (path:match("%.bib$") and "bib")
                or (path:match("%.tex$") or path:match("%.ltx$")) and "tex"
                or (path:match("%.sty$") and "package")
                or (path:match("%.cls$") and "class")
                or "graphics"
        end
        out[#out + 1] = { path = path, kind = kind }
    end
    add(root, "tex")
    for _, entry in ipairs(M.document(root)) do
        if entry.kind == "include" and entry.target then
            add(entry.target, entry.include)
        end
    end
    for _, path in ipairs(root_mod.graph(root)) do
        add(path, nil)
    end
    return out
end

--- The entry the cursor is inside: the LAST section-ish entry written in `file` at or above `lnum`.
--- The follow highlight and the "which section am I in" answer both come from here.
---@param entries LvimTexEntry[]
---@param file string
---@param lnum integer
---@return LvimTexEntry?
function M.entry_at(entries, file, lnum)
    local best = nil
    for _, entry in ipairs(entries) do
        if entry.file == file and entry.lnum <= lnum then
            if not best or entry.lnum >= best.lnum then
                best = entry
            end
        end
    end
    return best
end

--- A stable identity for an entry — the TOC's fold state, its follow mark and its cursor focus are
--- all keyed by it, so it must survive a refresh that did not move the entry.
---@param entry LvimTexEntry
---@return string
function M.id(entry)
    return ("%s:%s:%d:%d"):format(entry.kind, fs.basename(entry.file), entry.lnum, entry.col)
end

return M
