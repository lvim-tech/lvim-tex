-- lvim-tex: what you can DO with the citation key under the cursor (checklist row K8).
--
-- The project already has two answers about citations, and this is neither of them. Completion
-- (texlab, K1) answers "which key may I type here"; the `,lb` finder (`lvim-tex.pickers`) answers
-- "where is that entry". Neither answers the question a reader actually has with the cursor sitting
-- on `\cite{knuth1984tex}` — *take me to the thing itself*: the paper's DOI page, its publisher URL,
-- the PDF filed next to the bibliography, or the entry's own text.
--
-- Three things are deliberate:
--
--   • THE DATA LAYER IS SHARED, NOT COPIED. Entries come from `structure.bib_entries()` — the
--     `bibtex`-grammar scan of every bibliography the document pulls in, cached per file with the
--     rest of the document model. This module adds only the READING of an entry: which of its fields
--     is a link, and what a one-line summary of it says. The completion gap-fill and the action menu
--     both call the same two functions, so an entry can never read one way in one place and another
--     in the other.
--
--   • THE KEY COMES FROM THE PARSE TREE. `\cite[see][p.~3]{a,b,c}` puts three keys in one node; the
--     grammar splits them into `text` children, so "the key under the cursor" is the `text` node the
--     cursor is in — not a comma-split of the line, which would pick the wrong key from an optional
--     argument that itself contains a comma.
--
--   • EVERY TARGET GOES THROUGH `lvim-utils.utils.open_url`. It is the single place that knows
--     `vim.ui.open` reports failure by RETURNING `nil, err` rather than raising, so a missing
--     handler becomes a warning here instead of a silent no-op.
--
---@module "lvim-tex.cite"

local config = require("lvim-tex.config")
local nav = require("lvim-tex.nav")
local root_mod = require("lvim-tex.root")
local structure = require("lvim-tex.structure")
local ts = require("lvim-tex.ts")

local ui = require("lvim-ui")
local utils = require("lvim-utils.utils")

local api = vim.api
local fn = vim.fn
local fs = vim.fs

local M = {}

--- The pointer/separator glyph the whole ecosystem uses between the parts of one row.
local ARROW = "➤"

--- Node types whose text child IS a citation key.
---@type table<string, boolean>
local CITATION = { citation = true }

--- Notify, gated by `config.notify` for the informational levels (a warning always speaks).
---@param msg string
---@param level integer?
---@return nil
local function notify(msg, level)
    level = level or vim.log.levels.INFO
    if config.notify or level >= vim.log.levels.WARN then
        vim.notify("lvim-tex: " .. msg, level)
    end
end

--- The first non-empty value among `names` in `fields`.
---@param fields table<string, string>
---@param names string[]?
---@return string?
local function field(fields, names)
    for _, name in ipairs(names or {}) do
        local value = fields[name]
        if type(value) == "string" and vim.trim(value) ~= "" then
            return vim.trim(value)
        end
    end
    return nil
end

--- The citation KEY under a position, from the parse tree (nil when the cursor is not on one).
---@param buf integer?  defaults to the current buffer
---@param row integer?  0-based; defaults to the cursor
---@param col integer?  0-based; defaults to the cursor
---@return string?
function M.key_at(buf, row, col)
    local cbuf, crow, ccol = ts.cursor(0)
    buf = buf or cbuf
    row = row or crow
    col = col or ccol
    local node = ts.node_at(buf, row, col)
    if not node then
        return nil
    end
    -- Walk out to the citation first: only inside one is a `text` node a key (the same node type
    -- carries the optional argument's prose, `\cite[see][p.~3]{…}`).
    local citation = ts.ancestor(node, CITATION)
    if not citation then
        return nil
    end
    -- The innermost `text` ancestor is the one key the cursor is in; with the cursor on a brace or a
    -- comma there is none, and the citation's first key is the honest answer.
    local text = ts.ancestor(node, { text = true })
    if text and ts.contains({ text:range() }, row, col) then
        local key = vim.trim(ts.text(text, buf))
        if key ~= "" then
            return key
        end
    end
    for child in citation:iter_children() do
        if child:type():find("curly_group", 1, true) then
            for leaf in child:iter_children() do
                if leaf:type() == "text" then
                    local key = vim.trim(ts.text(leaf, buf))
                    if key ~= "" then
                        return key
                    end
                end
            end
        end
    end
    return nil
end

--- Every bibliography entry the project defines, keyed by its citation key.
---@param root string
---@return table<string, table>  key → the `structure.bib_entries` record
function M.entries(root)
    local out = {}
    for _, entry in ipairs(structure.bib_entries(root)) do
        -- First definition wins: a key defined twice is a bibliography error, and the first one is
        -- what biber itself uses.
        if not out[entry.key] then
            out[entry.key] = entry
        end
    end
    return out
end

--- The one-line description of an entry — its title, first author (with `et al.` when there are
--- more) and year, in that order, each part separated by the ecosystem's pointer glyph.
---
--- Shared with the completion gap-fill's documentation, so a key reads the same in the menu and in
--- the completion popup.
---@param entry table  a `structure.bib_entries` record
---@return string
function M.summary(entry)
    local fields = entry.fields or {}
    local parts = {}
    if fields.title and fields.title ~= "" then
        parts[#parts + 1] = fields.title
    end
    local who = fields.author or fields.editor
    if who and who ~= "" then
        local first = vim.split(who, " and ", { plain = true })[1]
        parts[#parts + 1] = vim.trim(first) .. (who:find(" and ", 1, true) and " et al." or "")
    end
    if fields.year and fields.year ~= "" then
        parts[#parts + 1] = fields.year
    end
    return table.concat(parts, ("  %s "):format(ARROW))
end

--- A `file` field's PATH. Biblatex/JabRef write it as `Description:path:TYPE` (either of the outer
--- parts may be empty) and separate several attachments with `;`; a bare path is also legal. The
--- longest colon-separated part that looks like a path is the file — a description rarely contains a
--- dot, and the type tag never does.
---@param value string
---@return string?
local function attachment(value)
    for _, one in ipairs(vim.split(value, ";", { plain = true })) do
        one = vim.trim(one)
        if one ~= "" then
            if not one:find(":", 1, true) then
                return one
            end
            local best = nil
            for part in one:gmatch("[^:]+") do
                if part:find("%.%a+$") and (not best or #part > #best) then
                    best = part
                end
            end
            if best then
                return best
            end
        end
    end
    return nil
end

--- Resolve an attachment path against the bibliography's own directory, then the root document's —
--- the two places a relative `file` field is ever written against.
---@param path string
---@param entry table
---@param root string
---@return string?
local function resolve_attachment(path, entry, root)
    if path:sub(1, 1) == "/" then
        return fn.filereadable(path) == 1 and path or nil
    end
    for _, dir in ipairs({ fs.dirname(entry.file), fs.dirname(root) }) do
        local candidate = fs.normalize(dir .. "/" .. path)
        if fn.filereadable(candidate) == 1 then
            return candidate
        end
    end
    return nil
end

--- What an entry can be OPENED as: its DOI page, its URL, its arXiv abstract, its attached file.
--- Every one is nil when the entry carries no field for it, which is what decides the action menu's
--- rows — a menu never offers a link that does not exist.
---@param entry table
---@param root string
---@return { doi: string?, url: string?, arxiv: string?, file: string?, file_missing: string? }
function M.targets(entry, root)
    local fields = entry.fields or {}
    local names = config.cite.fields or {}
    local out = {}

    local doi = field(fields, names.doi)
    if doi then
        -- A `doi` field is written both bare (`10.5555/x`) and already resolved; normalise to the
        -- bare identifier so the configured template is what decides the resolver.
        doi = doi:gsub("^doi:%s*", ""):gsub("^https?://[^/]*doi%.org/", "")
        out.doi = config.cite.doi_url:format(doi)
    end

    local url = field(fields, names.url)
    if url and url:find("^%a[%w+.-]*://") then
        out.url = url
    end

    local eprint = field(fields, names.arxiv)
    if eprint then
        local prefix = (field(fields, { "archiveprefix", "eprinttype" }) or "arxiv"):lower()
        if prefix == "arxiv" then
            out.arxiv = config.cite.arxiv_url:format(eprint)
        end
    end

    local file = field(fields, names.file)
    if file then
        local path = attachment(file)
        if path then
            local resolved = resolve_attachment(path, entry, root)
            if resolved then
                out.file = resolved
            else
                out.file_missing = path
            end
        end
    end
    return out
end

--- Open a URL (or a local file) through the shared helper, reporting what went wrong when it will
--- not open — `vim.ui.open` RETURNS its failure, so nothing else would say a word.
---@param target string
---@param what string   what is being opened, for the message
---@return nil
local function open(target, what)
    local ok, err = utils.open_url(target)
    if ok then
        notify(("%s %s"):format(config.icons.cite, target))
    else
        notify(("could not open the %s (%s)"):format(what, err or "no handler"), vim.log.levels.WARN)
    end
end

---@class LvimTexCiteAction
---@field id    string    stable identifier (what the proofs assert on)
---@field label string    the menu row
---@field icon  string    the row's glyph
---@field run   fun(): nil

--- The actions available for `key`, in menu order. An entry that no bibliography defines still gets
--- a menu: jumping to the CITATION is the useful answer there, and yanking the key still works.
---@param key string
---@param root string
---@param win integer?  the window a jump should land in
---@return LvimTexCiteAction[]
function M.actions(key, root, win)
    local entry = M.entries(root)[key]
    local actions = {}

    ---@param id string
    ---@param label string
    ---@param icon string
    ---@param run fun(): nil
    local function add(id, label, icon, run)
        actions[#actions + 1] = { id = id, label = label, icon = icon, run = run }
    end

    if entry then
        add(
            "goto",
            ("Go to the entry  %s  %s:%d"):format(ARROW, fn.fnamemodify(entry.file, ":t"), entry.lnum),
            config.icons.bib,
            function()
                nav.open_at(entry.file, entry.lnum, 1, { win = win })
            end
        )
        local targets = M.targets(entry, root)
        if targets.doi then
            add("doi", ("Open the DOI  %s  %s"):format(ARROW, targets.doi), config.icons.doc, function()
                open(targets.doi, "DOI")
            end)
        end
        if targets.url then
            add("url", ("Open the URL  %s  %s"):format(ARROW, targets.url), config.icons.doc, function()
                open(targets.url, "URL")
            end)
        end
        if targets.arxiv then
            add("arxiv", ("Open the arXiv page  %s  %s"):format(ARROW, targets.arxiv), config.icons.doc, function()
                open(targets.arxiv, "arXiv page")
            end)
        end
        if targets.file then
            add(
                "file",
                ("Open the attached file  %s  %s"):format(ARROW, fn.fnamemodify(targets.file, ":~:.")),
                config.icons.include,
                function()
                    open(targets.file, "attached file")
                end
            )
        elseif targets.file_missing then
            -- Named, not hidden: an entry that promises a PDF which is not where it says is exactly
            -- the thing the user wants to be told about.
            add(
                "file_missing",
                ("Attached file not found  %s  %s"):format(ARROW, targets.file_missing),
                config.icons.fail,
                function()
                    notify(
                        ("the entry's file field names %q, which is not readable"):format(targets.file_missing),
                        vim.log.levels.WARN
                    )
                end
            )
        end
    else
        local citations = structure.citations(root)
        local at = citations[key]
        if at then
            add(
                "goto_citation",
                ("No entry defines this key  %s  go to the citation"):format(ARROW),
                config.icons.fail,
                function()
                    nav.open_at(at.file, at.lnum, at.col, { win = win })
                end
            )
        end
    end

    add(
        "yank",
        ("Yank the key  %s  register %s"):format(ARROW, config.cite.yank_register),
        config.icons.label,
        function()
            fn.setreg(config.cite.yank_register, key)
            notify(("%s yanked %q to register %s"):format(config.icons.cite, key, config.cite.yank_register))
        end
    )

    return actions
end

--- Show the action menu for `key` on the canonical picker.
---@param key string
---@param root string
---@param win integer?
---@return nil
function M.menu(key, root, win)
    local actions = M.actions(key, root, win)
    local items = {}
    for _, action in ipairs(actions) do
        items[#items + 1] = { label = action.label, icon = action.icon }
    end
    ui.select({
        title = ("%s %s"):format(config.icons.cite, key),
        items = items,
        callback = function(confirmed, index)
            local action = confirmed and actions[index] or nil
            if action then
                action.run()
            end
        end,
    })
end

--- Choose a key first (the whole project's bibliography, plus any key cited without an entry), then
--- show its action menu. This is what `:LvimTex cite` does away from a citation.
---@param root string
---@param win integer?
---@return nil
function M.choose(root, win)
    local entries = structure.bib_entries(root)
    local citations = structure.citations(root)
    local defined, items, keys = {}, {}, {}
    for _, entry in ipairs(entries) do
        defined[entry.key] = true
        keys[#keys + 1] = entry.key
        items[#items + 1] = {
            label = ("%s  %s %s"):format(entry.key, ARROW, M.summary(entry)),
            icon = config.icons.cite,
        }
    end
    local missing = vim.tbl_keys(citations)
    table.sort(missing)
    for _, key in ipairs(missing) do
        if not defined[key] then
            keys[#keys + 1] = key
            items[#items + 1] = {
                label = ("%s  %s no entry in the bibliography"):format(key, ARROW),
                icon = config.icons.fail,
            }
        end
    end
    if #items == 0 then
        notify("this project has no bibliography entries", vim.log.levels.WARN)
        return
    end
    ui.select({
        title = ("%s Citations"):format(config.icons.cite),
        items = items,
        callback = function(confirmed, index)
            local key = confirmed and keys[index] or nil
            if key then
                M.menu(key, root, win)
            end
        end,
    })
end

--- `:LvimTex cite [key]` / `,lz` — the action menu for the key under the cursor, for an explicitly
--- named key, or (away from a citation) for one picked from the project's bibliography.
---@param key string?  an explicit key, from the command line
---@param buf integer?
---@return nil
function M.open(key, buf)
    buf = buf or api.nvim_get_current_buf()
    local root = root_mod.of(buf)
    if not root then
        notify("this buffer has no file on disk", vim.log.levels.WARN)
        return
    end
    local win = nav.code_win(api.nvim_get_current_win())
    key = (key and vim.trim(key) ~= "") and vim.trim(key) or M.key_at(buf)
    if key then
        M.menu(key, root, win)
    else
        M.choose(root, win)
    end
end

return M
