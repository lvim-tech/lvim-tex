-- lvim-tex: the project-wide finders — every file, every `\label`, every bibliography entry, in one
-- list you can jump from.
--
-- Completion answers "what may I type here"; these answer "where IS it". A label defined in a chapter
-- three files away, a citation key whose entry you want to read, the graphic an included file pulls
-- in — none of them is reachable from the buffer you are in, because the project only exists as the
-- include graph. Each finder is built on that graph and the treesitter scan of it (`lvim-tex.structure`),
-- so they see exactly what the document sees.
--
-- Presentation is the canonical `lvim-ui.select` — one themed, centered chooser, the same shape every
-- other lvim-tech list wears. Rows are COLUMN-ALIGNED (key, then context, then the position), measured
-- in display cells rather than bytes, because every one of them carries a Nerd glyph; `➤` separates a
-- row's parts, per the ecosystem's pointer canon.
--
-- The citation finder deliberately lists the BIBLIOGRAPHY, not the citations: the useful destination
-- of a key is the entry that defines it. A key that is cited but defined nowhere is still listed —
-- marked, and jumping to it lands on the citation — because a missing entry is exactly what the user
-- is usually hunting.
--
---@module "lvim-tex.pickers"

local config = require("lvim-tex.config")
local nav = require("lvim-tex.nav")
local root_mod = require("lvim-tex.root")
local structure = require("lvim-tex.structure")

local ui = require("lvim-ui")

local api = vim.api
local fn = vim.fn
local fs = vim.fs

local M = {}

--- The pointer/separator glyph the whole ecosystem uses between the parts of one row.
local ARROW = "➤"

--- Pad `text` to `width` DISPLAY columns (a Nerd glyph is one cell but several bytes, so byte padding
--- would leave every column that carries one short).
---@param text string
---@param width integer
---@return string
local function pad(text, width)
    return text .. string.rep(" ", math.max(0, width - fn.strdisplaywidth(text)))
end

--- The widest display width in `values`.
---@param values string[]
---@return integer
local function widest(values)
    local width = 0
    for _, value in ipairs(values) do
        width = math.max(width, fn.strdisplaywidth(value))
    end
    return width
end

--- The project the cursor is in, plus the window a jump should land in.
---@param buf integer?
---@return string?, integer?
local function project(buf)
    local root = root_mod.of(buf)
    if not root then
        vim.notify("lvim-tex: this buffer has no file on disk", vim.log.levels.WARN)
        return nil, nil
    end
    return root, nav.code_win(api.nvim_get_current_win())
end

--- `path` written relative to the root's directory (what a row shows as the position).
---@param path string
---@param root string
---@return string
local function relative(path, root)
    local base = fs.dirname(root)
    if vim.startswith(path, base .. "/") then
        return path:sub(#base + 2)
    end
    return fn.fnamemodify(path, ":~")
end

--- Open the chooser and jump to the picked item's `_at` position.
---@param title string
---@param items table[]   each item carries `_at = { path, lnum, col }`
---@param win integer?
---@return nil
local function choose(title, items, win)
    if #items == 0 then
        vim.notify("lvim-tex: nothing to list yet", vim.log.levels.INFO)
        return
    end
    ui.select({
        title = title,
        items = items,
        callback = function(confirmed, index)
            local item = confirmed and items[index] or nil
            if not item then
                return
            end
            nav.open_at(item._at.path, item._at.lnum, item._at.col, { win = win })
        end,
    })
end

--- Every file the project pulls in — the include graph, root first.
---@param buf integer?
---@return nil
function M.files(buf)
    local root, win = project(buf)
    if not root then
        return
    end
    local records = structure.files(root)
    local items = {}
    for _, record in ipairs(records) do
        local glyph = (record.kind == "bib" and config.icons.bib)
            or (record.kind == "graphics" and config.icons.graphics)
            or config.icons.include
        items[#items + 1] = {
            label = relative(record.path, root) .. (record.path == root and ("  %s root"):format(ARROW) or ""),
            icon = glyph,
            _at = { path = record.path, lnum = 1, col = 1 },
        }
    end
    choose(("%s Project files"):format(config.icons.include), items, win)
end

--- Every `\label` in the project, with the section it belongs to.
---@param buf integer?
---@return nil
function M.labels(buf)
    local root, win = project(buf)
    if not root then
        return
    end
    local labels = structure.labels(root)
    local keys = vim.tbl_map(function(label)
        return label.key
    end, labels)
    local width = widest(keys)
    local items = {}
    for _, label in ipairs(labels) do
        local context = label.context ~= "" and (" %s %s"):format(ARROW, label.context) or ""
        items[#items + 1] = {
            label = ("%s%s   %s:%d"):format(pad(label.key, width), context, relative(label.file, root), label.lnum),
            icon = config.icons.label,
            _at = { path = label.file, lnum = label.lnum, col = label.col },
        }
    end
    choose(("%s Labels"):format(config.icons.label), items, win)
end

--- The one-line description of a bibliography entry: its title, then its author and year.
---@param fields table<string, string>
---@return string
local function bib_summary(fields)
    local parts = {}
    if fields.title and fields.title ~= "" then
        parts[#parts + 1] = fields.title
    end
    local who = fields.author or fields.editor
    if who and who ~= "" then
        -- Only the first author: a nine-author entry would push everything else off the row.
        local first = vim.split(who, " and ", { plain = true })[1]
        parts[#parts + 1] = vim.trim(first) .. (who:find(" and ", 1, true) and " et al." or "")
    end
    if fields.year and fields.year ~= "" then
        parts[#parts + 1] = fields.year
    end
    return table.concat(parts, ("  %s "):format(ARROW))
end

--- Every bibliography entry the project defines, plus every citation key it uses that no entry
--- defines (marked, and jumping to one lands on the citation).
---@param buf integer?
---@return nil
function M.cites(buf)
    local root, win = project(buf)
    if not root then
        return
    end
    local entries = structure.bib_entries(root)
    local citations = structure.citations(root)
    local defined = {}
    local keys = {}
    for _, entry in ipairs(entries) do
        defined[entry.key] = true
        keys[#keys + 1] = entry.key
    end
    for key in pairs(citations) do
        if not defined[key] then
            keys[#keys + 1] = key
        end
    end
    local width = widest(keys)

    local items = {}
    for _, entry in ipairs(entries) do
        local used = citations[entry.key]
        items[#items + 1] = {
            label = ("%s %s %s   %s:%d%s"):format(
                pad(entry.key, width),
                ARROW,
                bib_summary(entry.fields),
                relative(entry.file, root),
                entry.lnum,
                used and "" or "   (not cited)"
            ),
            icon = config.icons.cite,
            _at = { path = entry.file, lnum = entry.lnum, col = 1 },
        }
    end
    -- The keys with no entry come last: they are the exceptions, and a list that opened on them would
    -- bury the bibliography itself.
    local missing = vim.tbl_keys(citations)
    table.sort(missing)
    for _, key in ipairs(missing) do
        if not defined[key] then
            local at = citations[key]
            items[#items + 1] = {
                label = ("%s %s no entry in the bibliography   %s:%d"):format(
                    pad(key, width),
                    ARROW,
                    relative(at.file, root),
                    at.lnum
                ),
                icon = config.icons.fail,
                _at = { path = at.file, lnum = at.lnum, col = at.col },
            }
        end
    end
    choose(("%s Citations"):format(config.icons.cite), items, win)
end

return M
