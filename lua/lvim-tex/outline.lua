-- lvim-tex: the TABLE OF CONTENTS panel — the whole document, across every file it includes, as one
-- navigable tree.
--
-- A LaTeX project is written in pieces and read as a whole, and no window in the editor shows the
-- whole: the chapter buffer knows nothing of the part it belongs to, and the root knows only the
-- `\input` lines. The TOC is that missing view — sections nested by their real depth regardless of
-- which file they were written in, with the includes, the labels and the TODO comments in their
-- places, jumpable, and tracking where the cursor is in the source.
--
-- WHAT THIS MODULE OWNS AND WHAT IT DOES NOT: the content is `lvim-tex.structure` (parse + cache +
-- numbering) and the panel is the SHARED `lvim-ui.tree` inside an `lvim-ui` surface — which already
-- owns the fold state, the indent guides, the marker column, the follow mark, the scrollbar, the
-- canonical `l`/`<CR>`/`h` keys, the mouse and the teardown. This module maps entries onto tree nodes,
-- binds the TOC's own keys, and answers "where is the cursor". Nothing here opens a window.
--
-- TWO LAYOUTS, one behaviour. `outline.layout = "split"` is a PERSISTENT docked panel beside the
-- document (the lvim-lsp outline shape) — the only layout in which follow-the-cursor is live, because
-- the source cursor keeps moving while the panel is open. `"float"` / `"area"` / `"bottom"` open the
-- same tree as a modal on the canonical `ui.tabs` chassis, where follow is what it can be there: the
-- row for the section the cursor was in is focused on open.
--
---@module "lvim-tex.outline"

local config = require("lvim-tex.config")
local nav = require("lvim-tex.nav")
local root_mod = require("lvim-tex.root")
local structure = require("lvim-tex.structure")

local ui = require("lvim-ui")
local surface = require("lvim-ui.surface")
local cursor = require("lvim-utils.cursor")
local hl = require("lvim-utils.highlight")

local api = vim.api
local fs = vim.fs

local M = {}

--- The panel buffer's filetype — the handle the cursor module hides the hardware cursor by, and what
--- a user's own autocmds can key on.
local FT = "lvim-tex-toc"

-- ─── theming (the standard build()-factory pipeline over the live palette) ─────

hl.bind(function(c)
    c = c or require("lvim-utils.colors")
    return {
        -- Sectioning depth reads as colour weight: the parts and chapters carry the document, the
        -- deeper levels are structure you scan past.
        LvimTexTocSection = { fg = c.blue, bold = true },
        LvimTexTocSubsection = { fg = c.cyan },
        LvimTexTocDeep = { fg = hl.blend(c.cyan, c.bg, 0.7) },
        LvimTexTocNumber = { fg = hl.blend(c.blue, c.bg, 0.6) },
        LvimTexTocInclude = { fg = c.yellow },
        LvimTexTocLabel = { fg = c.green },
        LvimTexTocTodo = { fg = c.orange },
        LvimTexTocMissing = { fg = c.red },
        LvimTexTocDetail = { fg = c.comment },
        LvimTexTocFile = { fg = hl.blend(c.fg_dark, c.bg, 0.7), italic = true },
        LvimTexTocFold = { fg = c.blue },
        LvimTexTocMark = { bg = hl.blend(c.blue, c.bg, 0.16), bold = true },
    }
end)

-- ─── state ────────────────────────────────────────────────────────────────────

---@class LvimTexTocState
---@field panel   table?    the lvim-ui.tree handle (rebuilt per open — a handle is single-surface)
---@field surface table?    the docked surface, when `layout = "split"`
---@field handle  table?    the ui.tabs handle, for every other layout
---@field root    string?   the project this TOC describes
---@field src_win integer?  the window the panel was opened from — where a jump lands
---@field entries LvimTexEntry[]  the flat document, as of the last refresh
---@field nodes   table<string, LvimTexEntry>  node id → the entry it renders
---@field show    table<string, boolean>  runtime row toggles (seeded from `outline.show`)
---@field query   string    the live filter, "" when none
---@field depth   integer   fold depth (0 = every level open)
---@field layout  string?   the per-open layout override, sticky for the session
---@field augroup integer?
local state = {
    panel = nil,
    surface = nil,
    handle = nil,
    root = nil,
    src_win = nil,
    entries = {},
    nodes = {},
    show = {},
    query = "",
    depth = 0,
    layout = nil,
    augroup = nil,
}

--- The live `outline` config block.
---@return table
local function cfg()
    return config.outline
end

--- Rows for the help window (config key name → what it does), in display order.
---@type { [1]: string, [2]: string }[]
local HELP = {
    { "activate", "jump to the entry (closes the panel when `auto_close`)" },
    { "peek", "jump there but keep the cursor in the panel" },
    { "expand", "expand the section / jump when it has no children" },
    { "collapse", "collapse the section / go to its parent" },
    { "fold_more", "fold one level shallower" },
    { "fold_less", "unfold one level deeper" },
    { "levels", "fold to that sectioning depth" },
    { "expand_all", "unfold everything" },
    { "collapse_all", "fold everything" },
    { "toggle_includes", "show / hide the include rows" },
    { "toggle_labels", "show / hide the label rows" },
    { "toggle_todos", "show / hide the TODO rows" },
    { "toggle_numbers", "show / hide the section numbers" },
    { "filter", "filter the tree by a string" },
    { "actions", "actions for the entry under the cursor" },
    { "refresh", "re-read the document" },
    { "help", "this window" },
    { "close", "close the panel" },
}

-- ─── nodes ────────────────────────────────────────────────────────────────────

--- The glyph and highlight a row wears, from its kind (and, for a section, its depth).
---@param entry LvimTexEntry
---@return string icon, string group
local function decorate(entry)
    local icons = config.icons
    if entry.kind == "section" then
        local group = (entry.level <= 3 and "LvimTexTocSection")
            or (entry.level <= 4 and "LvimTexTocSubsection")
            or "LvimTexTocDeep"
        return icons.section, group
    elseif entry.kind == "include" then
        local glyph = (entry.include == "graphics" and icons.graphics)
            or (entry.include == "bib" and icons.bib)
            or icons.include
        return glyph, entry.target and "LvimTexTocInclude" or "LvimTexTocMissing"
    elseif entry.kind == "label" then
        return icons.label, "LvimTexTocLabel"
    end
    return icons.todo, "LvimTexTocTodo"
end

--- The text of one row: the section number (when numbering is on), then the title.
---@param entry LvimTexEntry
---@return string
local function row_label(entry)
    if entry.kind == "section" then
        local number = (state.show.numbers and entry.number) and (entry.number .. " ") or ""
        return number .. (entry.title ~= "" and entry.title or "(untitled)")
    end
    if entry.kind == "todo" and entry.keyword and entry.title ~= entry.keyword then
        return ("%s %s"):format(entry.keyword, entry.title)
    end
    return entry.title
end

--- `path` relative to the project root's directory (an absolute path outside it is kept whole) — the
--- form a TOC row can carry without eating the width.
---@param path string
---@return string
local function relative(path)
    local base = state.root and fs.dirname(state.root) or nil
    if base and vim.startswith(path, base .. "/") then
        return path:sub(#base + 2)
    end
    return vim.fn.fnamemodify(path, ":~")
end

--- The dim end-of-line text: what the row points AT, when that is not already its label.
---@param entry LvimTexEntry
---@return string?
local function row_detail(entry)
    if entry.kind == "section" and entry.label then
        return ("%s %s"):format(config.icons.label, entry.label)
    end
    if entry.kind == "include" then
        if not entry.target then
            return "not found"
        end
        -- Only when it says something the row does not: an include whose argument already IS the
        -- resolved path (a `.bib`, a graphic written with its extension) would print itself twice.
        local target = relative(entry.target)
        return target ~= entry.title and target or nil
    end
    return nil
end

--- Does `entry` (or anything under it) match the live filter?
---@param entry LvimTexEntry
---@return boolean
local function matches(entry)
    if state.query == "" then
        return true
    end
    local needle = state.query:lower()
    return (entry.title or ""):lower():find(needle, 1, true) ~= nil
        or (entry.label or ""):lower():find(needle, 1, true) ~= nil
end

--- Build the tree the panel renders from the flat document.
---
--- The hierarchy is rebuilt from the LEVELS (see the structure module): a section pops every open
--- section at or below its own depth and becomes their sibling or the child of what is left; every
--- other row attaches to the section it was written under. A filter keeps a section whose title
--- matches AND any section that has a surviving descendant, so filtering never orphans a match.
---@return table[]  lvim-ui.tree nodes
local function build_nodes()
    local roots, stack = {}, {}
    state.nodes = {}

    ---@param entry LvimTexEntry
    ---@return table
    local function make(entry)
        local icon, group = decorate(entry)
        local id = structure.id(entry)
        state.nodes[id] = entry
        local node = {
            id = id,
            label = row_label(entry),
            icon = icon,
            hl = group,
            kind = entry.kind,
            detail = row_detail(entry),
            children = {},
            data = entry,
        }
        -- Which FILE a row lives in matters only when it is not the root's own — an included chapter's
        -- rows say so, the root's stay clean.
        if state.root and entry.file ~= state.root then
            -- A leading space of its own: the badge is right-aligned against whatever the row's dim
            -- detail text ends at, and on a narrow panel the two would otherwise touch.
            node.badges = { { " " .. fs.basename(entry.file), "LvimTexTocFile" } }
        end
        return node
    end

    for _, entry in ipairs(state.entries) do
        local wanted = entry.kind == "section"
            or (entry.kind == "include" and state.show.includes)
            or (entry.kind == "label" and state.show.labels)
            or (entry.kind == "todo" and state.show.todos)
        if wanted and entry.level <= (cfg().max_level or structure.MAX_LEVEL) then
            local node = make(entry)
            if entry.kind == "section" then
                while #stack > 0 and stack[#stack].level >= entry.level do
                    table.remove(stack)
                end
                local parent = stack[#stack]
                if parent then
                    parent.node.children[#parent.node.children + 1] = node
                else
                    roots[#roots + 1] = node
                end
                stack[#stack + 1] = { level = entry.level, node = node }
            else
                local parent = stack[#stack]
                if parent then
                    parent.node.children[#parent.node.children + 1] = node
                else
                    roots[#roots + 1] = node
                end
            end
        end
    end

    if state.query == "" then
        return roots
    end

    --- Prune to the matching rows and the ancestors that lead to them.
    ---@param nodes table[]
    ---@return table[]
    local function prune(nodes)
        local kept = {}
        for _, node in ipairs(nodes) do
            local children = prune(node.children)
            if #children > 0 or matches(node.data) then
                node.children = children
                kept[#kept + 1] = node
            end
        end
        return kept
    end
    return prune(roots)
end

--- Apply the current fold depth: every section shallower than `depth` open, everything from it down
--- folded. `depth = 0` means "no depth folding" — the tree's own default (all open) stands.
---@return nil
local function apply_depth()
    if not state.panel then
        return
    end
    if state.depth <= 0 then
        state.panel.set_expanded({})
        return
    end
    local map = {}
    for id, entry in pairs(state.nodes) do
        map[id] = entry.level < state.depth
    end
    state.panel.set_expanded(map)
end

-- ─── the source side ──────────────────────────────────────────────────────────

--- Is the panel open?
---@return boolean
function M.is_open()
    return state.panel ~= nil and state.panel.valid()
end

--- Highlight the row for the position the SOURCE cursor is at (the shared tree's `mark`, which also
--- parks the panel cursor on it while the user is not inside the panel).
---@return nil
function M.follow()
    if not (cfg().follow and M.is_open()) then
        return
    end
    local win = state.src_win
    if not (win and api.nvim_win_is_valid(win)) then
        return
    end
    local buf = api.nvim_win_get_buf(win)
    local file = vim.fn.fnamemodify(api.nvim_buf_get_name(buf), ":p")
    local entry = structure.entry_at(state.entries, file, api.nvim_win_get_cursor(win)[1])
    -- Only ROWS THAT EXIST can be marked: a filtered-out or folded-away entry has no id in the tree.
    local id = entry and structure.id(entry) or nil
    state.panel.mark(id and state.nodes[id] and id or nil, { move_cursor = true })
end

--- Jump to `entry`.
---@param entry LvimTexEntry?
---@param opts { close?: boolean, focus?: boolean, cmd?: string }?
---@return nil
local function jump(entry, opts)
    if not entry then
        return
    end
    opts = opts or {}
    -- An include row points at the FILE it names, not at the line the `\input` is written on: that is
    -- the whole reason it is in the tree.
    local target = entry.target
    local path, lnum, col = entry.file, entry.lnum, entry.col
    if entry.kind == "include" and target then
        path, lnum, col = target, 1, 1
    end
    if opts.close then
        M.close()
    end
    nav.open_at(path, lnum, col, { win = state.src_win, cmd = opts.cmd, focus = opts.focus })
    if not opts.close and opts.focus ~= false then
        state.src_win = nav.code_win(state.src_win)
    end
end

--- The entry under the panel cursor.
---@return LvimTexEntry?
local function selected()
    if not M.is_open() then
        return nil
    end
    local node = state.panel.selected()
    return node and node.data or nil
end

-- ─── refresh ──────────────────────────────────────────────────────────────────

--- Re-read the document and repaint. The per-file cache means only the files that actually changed
--- are re-parsed, so this is cheap enough to run on every toggle.
---@param opts { keep_folds?: boolean }?
---@return nil
function M.refresh(opts)
    if not (M.is_open() and state.root) then
        return
    end
    opts = opts or {}
    state.entries = structure.document(state.root)
    state.panel.set_root(build_nodes())
    state.panel.render()
    if not opts.keep_folds then
        apply_depth()
    end
    M.follow()
end

-- ─── actions ──────────────────────────────────────────────────────────────────

--- Show only the rows matching `query` (and the sections leading to them). `""` clears the filter.
---@param query string
---@return nil
function M.filter(query)
    state.query = vim.trim(query or "")
    M.refresh({ keep_folds = true })
end

--- Fold the tree to `depth`: every section shallower than it stays open, the rest folds. `0` unfolds.
---@param depth integer
---@return nil
function M.fold_to(depth)
    if not M.is_open() then
        return
    end
    state.depth = math.max(0, math.min(structure.MAX_LEVEL, depth))
    apply_depth()
    state.panel.render()
end

--- Flip one of the row-kind toggles (`includes`, `labels`, `todos`, `numbers`) and repaint.
---@param name string
---@return nil
function M.toggle_rows(name)
    if not M.is_open() then
        return
    end
    state.show[name] = not state.show[name]
    M.refresh({ keep_folds = true })
end

--- The filter prompt — the canonical input; an empty answer clears the filter.
---@return nil
local function ask_filter()
    ui.input({
        title = "Filter the table of contents",
        default = state.query,
        callback = function(confirmed, value)
            if confirmed then
                M.filter(value or "")
            end
        end,
    })
end

--- The per-row action menu (the canonical select) — everything a row can do beyond jumping to it.
---@return nil
local function ask_actions()
    local entry = selected()
    if not entry then
        return
    end
    local items = {}
    ---@param label string
    ---@param icon string
    ---@param run fun()
    local function item(label, icon, run)
        items[#items + 1] = { label = label, icon = icon, _run = run }
    end
    item("Jump to it", config.icons.section, function()
        jump(entry, { close = cfg().auto_close })
    end)
    item("Open in a split", config.icons.include, function()
        jump(entry, { cmd = "split" })
    end)
    item("Open in a vertical split", config.icons.include, function()
        jump(entry, { cmd = "vsplit" })
    end)
    item("Yank the title", config.icons.doc, function()
        vim.fn.setreg(vim.v.register or '"', entry.title)
    end)
    if entry.label then
        item(("Yank \\ref{%s}"):format(entry.label), config.icons.label, function()
            vim.fn.setreg(vim.v.register or '"', ("\\ref{%s}"):format(entry.label))
        end)
    end
    if entry.kind == "include" and entry.target then
        item("Yank the path", config.icons.include, function()
            vim.fn.setreg(vim.v.register or '"', entry.target)
        end)
    end
    ui.select({
        title = ("%s %s"):format(config.icons.toc, entry.title),
        items = items,
        callback = function(ok, index)
            if ok and items[index] then
                items[index]._run()
            end
        end,
    })
end

--- The keymap cheatsheet, through the shared help window.
---@return nil
local function show_help()
    local keys = cfg().keys or {}
    local items = {}
    for _, row in ipairs(HELP) do
        local lhs = keys[row[1]]
        if type(lhs) == "table" then
            -- The fold-depth keys are a RANGE, not an alternative list: printing "1 / 2 / 3 / 4 …"
            -- would say the same thing seven times.
            lhs = (row[1] == "levels") and ("%s-%s"):format(lhs[1], lhs[#lhs]) or table.concat(lhs, " / ")
        end
        if lhs then
            items[#items + 1] = { tostring(lhs), row[2] }
        end
    end
    ui.help({ title = "Table of contents", items = items, close_keys = { "q", "<Esc>" } })
end

--- Bind the TOC's config keys on the panel buffer (the tree's `on_keys` hook — bound AFTER the
--- canonical `l`/`<CR>`/`h`, so a config key on the same lhs wins).
---@param map fun(lhs: string|string[], fn: fun())
---@return nil
local function set_keys(map)
    local actions = {
        activate = function()
            jump(selected(), { close = cfg().auto_close })
        end,
        peek = function()
            jump(selected(), { focus = false })
        end,
        expand = function()
            state.panel.expand_or_activate()
        end,
        collapse = function()
            state.panel.collapse_or_parent()
        end,
        fold_more = function()
            M.fold_to(state.depth - 1)
        end,
        fold_less = function()
            M.fold_to(state.depth + 1)
        end,
        expand_all = function()
            state.depth = 0
            state.panel.expand_all()
        end,
        collapse_all = function()
            state.depth = 1
            state.panel.collapse_all()
        end,
        toggle_includes = function()
            M.toggle_rows("includes")
        end,
        toggle_labels = function()
            M.toggle_rows("labels")
        end,
        toggle_todos = function()
            M.toggle_rows("todos")
        end,
        toggle_numbers = function()
            M.toggle_rows("numbers")
        end,
        filter = ask_filter,
        actions = ask_actions,
        refresh = function()
            structure.invalidate()
            M.refresh()
        end,
        help = show_help,
        close = M.close,
    }
    for action, lhs in pairs(cfg().keys or {}) do
        if actions[action] then
            map(lhs, actions[action])
        end
    end
    -- Fold TO a depth: the level keys are a list, index = the level they fold to.
    for level, lhs in ipairs(cfg().keys.levels or {}) do
        map(lhs, function()
            M.fold_to(level)
        end)
    end
end

-- ─── lifecycle ────────────────────────────────────────────────────────────────

--- The TeX buffer the panel should describe: the current one when it is a TeX buffer (the everyday
--- case), else any loaded one — `:LvimTex toc` typed from the quickfix window still means "the
--- document I am working on".
---@param buf integer?
---@return integer?
local function tex_buffer(buf)
    ---@param b integer?
    ---@return boolean
    local function is_tex(b)
        return b ~= nil
            and b > 0
            and api.nvim_buf_is_loaded(b)
            and vim.tbl_contains(config.filetypes, vim.bo[b].filetype)
    end
    local given = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
    if is_tex(given) then
        return given
    end
    for _, win in ipairs(api.nvim_list_wins()) do
        if is_tex(api.nvim_win_get_buf(win)) then
            return api.nvim_win_get_buf(win)
        end
    end
    for _, b in ipairs(api.nvim_list_bufs()) do
        if is_tex(b) then
            return b
        end
    end
    return nil
end

--- Re-follow while the cursor moves in the document, and re-read it after a write. Only ever
--- meaningful for the docked layout, where the source stays reachable while the panel is open.
---@return nil
local function setup_autocmds()
    state.augroup = api.nvim_create_augroup("LvimTexToc", { clear = true })
    api.nvim_create_autocmd("CursorMoved", {
        group = state.augroup,
        desc = "lvim-tex: follow the cursor in the TOC",
        callback = function(args)
            if M.is_open() and args.buf ~= state.panel.buf() then
                M.follow()
            end
        end,
    })
    api.nvim_create_autocmd("BufWritePost", {
        group = state.augroup,
        pattern = { "*.tex", "*.ltx", "*.bib" },
        desc = "lvim-tex: re-read the document into the TOC after a write",
        callback = function()
            if M.is_open() then
                M.refresh({ keep_folds = true })
            end
        end,
    })
end

--- The footer chips both layouts wear.
---@return table[]
local function footer_items()
    local keys = cfg().keys or {}
    ---@param lhs string|string[]|nil
    ---@return string
    local function label(lhs)
        return type(lhs) == "table" and (lhs[1] or "?") or tostring(lhs or "?")
    end
    return {
        { key = label(keys.filter), name = "filter", run = ask_filter },
        { key = label(keys.help), name = "help", run = show_help },
        {
            key = label(keys.close),
            name = "close",
            run = function()
                M.close()
            end,
        },
    }
end

--- Open the table of contents.
---@param opts { buf?: integer, layout?: string, enter?: boolean }?
---@return nil
function M.open(opts)
    opts = opts or {}
    if M.is_open() then
        M.close()
    end
    local buf = tex_buffer(opts.buf)
    if not buf then
        vim.notify("lvim-tex: open a TeX buffer to see its table of contents", vim.log.levels.WARN)
        return
    end
    local root = root_mod.of(buf)
    if not root then
        vim.notify("lvim-tex: this buffer has no file on disk", vim.log.levels.WARN)
        return
    end

    -- The panel hides the hardware cursor while it is the CURRENT window (a persistent side panel must
    -- not hide it in the code beside it) — self-registered, so installing lvim-tex needs no edit to
    -- any central cursor config.
    cursor.register({ panel_ft = { FT } })

    if opts.layout then
        state.layout = opts.layout -- a per-command override is sticky for the session
    end
    local layout = state.layout or cfg().layout or "split"
    state.root = root
    state.src_win = nav.code_win(api.nvim_get_current_win())
    state.show = vim.tbl_extend("force", {}, cfg().show or {})
    state.depth = cfg().fold_level or 0
    state.query = ""
    state.entries = structure.document(root)

    local title = ("%s %s"):format(config.icons.toc, structure.title(root) or fs.basename(root))

    state.panel = ui.tree({
        default_expanded = true, -- a TOC opens READ, not folded; the depth keys fold it
        connectors = true,
        elide_guides = true,
        scrollbar = true,
        empty = " No sections",
        filetype = FT,
        cursorline = true,
        hide_cursor = layout ~= "split", -- a modal panel owns the screen; the dock does not
        hl = {
            fold = "LvimTexTocFold",
            detail = "LvimTexTocDetail",
            mark = "LvimTexTocMark",
            empty = "LvimTexTocDetail",
        },
        size = layout == "split" and function()
            local width = cfg().width or 0.28
            local columns = (width <= 1) and math.floor(vim.o.columns * width) or math.floor(width)
            return math.max(24, columns), 1
        end or nil,
        on_activate = function(node)
            jump(node and node.data or nil, { close = cfg().auto_close })
        end,
        on_keys = function(map)
            set_keys(map)
        end,
        on_close = function()
            if state.augroup then
                pcall(api.nvim_del_augroup_by_id, state.augroup)
                state.augroup = nil
            end
            state.panel, state.surface, state.handle = nil, nil, nil
        end,
    })
    state.panel.set_root(build_nodes())

    if layout == "split" then
        state.surface = surface.open({
            mode = "split",
            native = true, -- a REAL split: native `<C-w>` navigation and redraw beside the document
            dock = cfg().position == "left" and "left" or "right",
            enter = opts.enter ~= false,
            persistent = true,
            normal_hl = "NormalSB",
            title = title,
            size = { width = { fixed = cfg().width or 0.28 } },
            content = { blocks = { { id = "toc", provider = state.panel.provider } } },
            close_keys = {}, -- persistent: the TOC's own `close` key tears the panel down
            footer = {
                bars = {
                    {
                        align = "center",
                        items = vim.tbl_map(function(chip)
                            return surface.button({
                                name = chip.name,
                                key = chip.key,
                                style = "action",
                                run = chip.run,
                            }, "action")
                        end, footer_items()),
                    },
                },
            },
            footer_nav = true,
        })
    else
        state.handle = ui.tabs({
            title = { icon = config.icons.toc, text = structure.title(root) or fs.basename(root) },
            title_pos = "center",
            tabs = {
                {
                    label = "Contents",
                    icon = config.icons.section,
                    name = "toc",
                    provider = state.panel.provider,
                    footer = vim.tbl_map(function(chip)
                        return { key = chip.key, label = chip.name, no_hotkey = true, run = chip.run }
                    end, footer_items()),
                },
            },
            layout = layout,
            close_keys = { "q", "<Esc>" },
            callback = function()
                state.panel, state.surface, state.handle = nil, nil, nil
            end,
        })
    end

    apply_depth()
    setup_autocmds()
    M.follow()
end

--- Close the panel (a no-op when it is not open).
---@return nil
function M.close()
    local frame = state.surface or state.handle
    state.surface, state.handle = nil, nil
    if frame and frame.close then
        pcall(frame.close)
    end
    if state.augroup then
        pcall(api.nvim_del_augroup_by_id, state.augroup)
        state.augroup = nil
    end
    state.panel = nil
end

--- Toggle the panel.
---@param opts { buf?: integer, layout?: string, enter?: boolean }?
---@return nil
function M.toggle(opts)
    if M.is_open() then
        M.close()
    else
        M.open(opts)
    end
end

--- The flat document the panel is showing (the proofs and `:LvimTex info` read it).
---@return LvimTexEntry[]
function M.entries()
    return state.entries
end

--- The ROWS the panel is showing right now, in display order — what the toggles, the fold depth and
--- the filter actually did, as opposed to what the document holds.
---@return table[]  lvim-ui.tree nodes
function M.visible()
    return M.is_open() and state.panel.visible() or {}
end

return M
