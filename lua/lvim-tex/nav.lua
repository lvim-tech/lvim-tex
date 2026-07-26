-- lvim-tex: the file UNDER THE CURSOR — `gf` for every TeX include, and the ONE place an include
-- argument is turned into a path on disk.
--
-- Neovim's built-in `gf` cannot do this. What a TeX include names is not a path as the shell knows
-- one:
--   • the extension is usually absent (`\input{chapters/ch1}` is `chapters/ch1.tex`), and WHICH
--     extension depends on the command — a graphic may be `.pdf`, `.png`, `.jpg`, an `\addbibresource`
--     is `.bib`, `\usepackage` is a `.sty` that lives in the TeX distribution, not in the project;
--   • the path is relative to the directory the ENGINE runs in — the compile target's own directory,
--     which for an included chapter is NOT the directory of the file the cursor is in. Both are tried,
--     the current file's first, so a project that writes root-relative paths and one that writes
--     sibling-relative paths both work;
--   • `\includegraphics` additionally searches every directory the preamble declared in
--     `\graphicspath`, which no generic resolver can guess;
--   • `\import{dir/}{file}` splits the path across TWO arguments.
--
-- Which include the cursor is on is read from the treesitter tree, not a line regex: the node types
-- ARE the classification (`graphics_include` vs `biblatex_include` vs `latex_include`), so the
-- extension list follows from the parse instead of from a guess about the command name. When the
-- cursor is not on an include at all, the built-in `gf` runs unchanged — this only ever ADDS answers.
--
-- `open_at` lives here too, and every jump in the plugin goes through it: a panel must never `:edit`
-- into itself, so "the window a file opens in" has exactly one definition (see the function).
--
---@module "lvim-tex.nav"

local config = require("lvim-tex.config")
local root_mod = require("lvim-tex.root")

local api = vim.api
local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

local M = {}

--- Include node type → the KIND of resource it names. The kind picks the extension list and the
--- search path; it is also what `lvim-tex.structure` labels an include row with.
---@type table<string, string>
M.KIND = {
    latex_include = "tex", -- \input, \include, \subfile, \subfileinclude
    import_include = "tex", -- \import / \subimport (directory + file)
    verbatim_include = "tex", -- \verbatiminput and friends
    graphics_include = "graphics", -- \includegraphics
    svg_include = "graphics", -- \includesvg
    inkscape_include = "graphics", -- \includeinkscape
    bibtex_include = "bib", -- \bibliography
    biblatex_include = "bib", -- \addbibresource
    bibstyle_include = "style", -- \bibliographystyle → a .bst
    class_include = "class", -- \documentclass → a .cls (usually in the distribution)
    package_include = "package", -- \usepackage → a .sty (usually in the distribution)
}

--- Kinds whose target is itself a TeX document, so the include graph RECURSES into it.
---@type table<string, boolean>
M.RECURSIVE = { tex = true }

--- The extension a distribution-provided kind carries, for the `kpsewhich` lookup.
---@type table<string, string>
local DIST_EXT = { class = ".cls", package = ".sty", style = ".bst" }

--- `\graphicspath` directories per root file, keyed by the fingerprint of the file they were read
--- from, so a preamble edit is picked up without re-reading the file on every resolve.
---@type table<string, { stamp: string, dirs: string[] }>
local graphicspath_cache = {}

--- Absolute, existing form of `path`, or nil. A directory never counts: an include names a FILE, and
--- `\input{chapters}` next to a `chapters/` directory must not resolve to the directory.
---@param path string?
---@return string?
local function real(path)
    if not path or path == "" then
        return nil
    end
    local abs = fn.fnamemodify(fs.normalize(path), ":p")
    local stat = uv.fs_stat(abs)
    if not stat or stat.type ~= "file" then
        return nil
    end
    return (abs:gsub("/$", ""))
end

--- A cheap change fingerprint for `path` — the loaded buffer's changedtick when it has one (so an
--- UNSAVED edit invalidates), else the file's mtime and size.
---@param path string
---@return string
function M.stamp(path)
    local buf = fn.bufnr(path)
    if buf ~= -1 and api.nvim_buf_is_loaded(buf) and vim.bo[buf].modified then
        return ("b%d:%d"):format(buf, api.nvim_buf_get_changedtick(buf))
    end
    local stat = uv.fs_stat(path)
    if not stat then
        return "missing"
    end
    return ("%d:%d:%d"):format(stat.mtime.sec, stat.mtime.nsec, stat.size)
end

--- The text of `path` — from the LOADED buffer when there is one (so unsaved edits are honoured),
--- otherwise from disk. Returns nil when neither can be read.
---@param path string
---@return string?
function M.read(path)
    local buf = fn.bufnr(path)
    if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
        return table.concat(api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
    end
    local ok, lines = pcall(fn.readfile, path)
    if not ok or type(lines) ~= "table" then
        return nil
    end
    return table.concat(lines, "\n")
end

--- The directories `\graphicspath{{a/}{b/}}` declares in `root`, absolute. Read with a pattern rather
--- than the parser: this runs inside `resolve`, which the include-graph scan calls for every graphic,
--- and the declaration is a preamble one-liner.
---@param root string
---@return string[]
local function graphics_dirs(root)
    local stamp = M.stamp(root)
    local hit = graphicspath_cache[root]
    if hit and hit.stamp == stamp then
        return hit.dirs
    end
    local dirs = {}
    local src = M.read(root)
    -- `\graphicspath{{a/}{b/}}` — the OUTER braces hold the list, each inner pair one directory. The
    -- outer pair has to come off first: a balanced match over the whole argument would take the outer
    -- pair itself as the first (and only) "directory".
    local group = src and src:match("\\graphicspath%s*(%b{})") or nil
    if group then
        for dir in group:sub(2, -2):gmatch("%b{}") do
            dir = dir:sub(2, -2)
            if dir ~= "" then
                dirs[#dirs + 1] = dir:sub(1, 1) == "/" and dir or fs.normalize(fs.dirname(root) .. "/" .. dir)
            end
        end
    end
    graphicspath_cache[root] = { stamp = stamp, dirs = dirs }
    return dirs
end

--- The directories an include of `kind` written in `file` is searched in, in order: the including
--- file's own directory first (a chapter that says `figures/x` means ITS figures), then the root
--- document's directory (the engine's working directory, which is what LaTeX itself resolves
--- against), then the `\graphicspath` list for graphics.
---@param kind string
---@param file string?  the file the include is written in
---@param root string?  the project's root document
---@return string[]
function M.search_dirs(kind, file, root)
    local dirs, seen = {}, {}
    ---@param dir string?
    local function add(dir)
        if dir and dir ~= "" and not seen[dir] then
            seen[dir] = true
            dirs[#dirs + 1] = dir
        end
    end
    add(file and fs.dirname(file) or nil)
    add(root and fs.dirname(root) or nil)
    if kind == "graphics" and root then
        for _, dir in ipairs(graphics_dirs(root)) do
            add(dir)
        end
    end
    return dirs
end

--- Resolve an include argument to a file on disk.
---
--- `spec` is tried in every directory of `dirs` with every extension configured for `kind` (the empty
--- one first, so an explicit extension always wins over a guessed one). A distribution kind
--- (`\usepackage`, `\documentclass`) that is not in the project falls through to `kpsewhich`, which is
--- the only thing that knows where a TeX distribution keeps its `.sty`.
---@param spec string   the raw include argument
---@param kind string   a value of `M.KIND`
---@param dirs string[] directories to search, in order (see `M.search_dirs`)
---@return string? path, string[] tried  the resolved file, or nil plus every candidate that was tried
function M.resolve(spec, kind, dirs)
    local tried = {}
    spec = vim.trim(spec or ""):gsub('^"(.*)"$', "%1")
    if spec == "" then
        return nil, tried
    end
    local exts = config.nav.extensions[kind] or { "" }
    -- An absolute spec names exactly one place; the search directories do not apply to it.
    local bases = spec:sub(1, 1) == "/" and { spec } or nil
    if not bases then
        bases = {}
        for _, dir in ipairs(dirs) do
            bases[#bases + 1] = dir .. "/" .. spec
        end
    end
    for _, base in ipairs(bases) do
        for _, ext in ipairs(exts) do
            local candidate = base .. ext
            tried[#tried + 1] = candidate
            local hit = real(candidate)
            if hit then
                return hit, tried
            end
        end
    end

    local dist = DIST_EXT[kind]
    if dist and config.nav.kpsewhich and fn.executable(config.nav.kpsewhich) == 1 then
        local name = spec:match("%" .. dist .. "$") and spec or (spec .. dist)
        tried[#tried + 1] = ("%s %s"):format(config.nav.kpsewhich, name)
        local out = vim.system({ config.nav.kpsewhich, name }, { text = true }):wait()
        local first = vim.split(out.stdout or "", "\n", { plain = true })[1]
        local hit = real(vim.trim(first or ""))
        if hit then
            return hit, tried
        end
    end
    return nil, tried
end

--- The include node containing `node`, or nil — walks up, so the cursor may sit anywhere on the
--- command, the braces or the argument.
---@param node TSNode?
---@return TSNode?, string?  the include node and its kind
local function include_ancestor(node)
    while node do
        local kind = M.KIND[node:type()]
        if kind then
            return node, kind
        end
        node = node:parent()
    end
    return nil, nil
end

--- Every target leaf of an include node, in source order. The grammar uses `path` for ordinary
--- includes and `glob_pattern` for `\addbibresource`, whose argument is formally a glob.
---@param node TSNode
---@param src string|integer  the source string, or a buffer number
---@return string[]
local function target_leaves(node, src)
    local out = {}
    ---@param n TSNode
    local function walk(n)
        for child in n:iter_children() do
            local kind = child:type()
            if kind == "path" or kind == "glob_pattern" then
                out[#out + 1] = vim.treesitter.get_node_text(child, src)
            else
                walk(child)
            end
        end
    end
    walk(node)
    return out
end

--- One include argument, joined the way its command spells it. `\import{dir/}{file}` splits the path
--- across two arguments; every other include names it in one. A multi-target include
--- (`\addbibresource` may be given a comma list) is split by the caller.
---@param leaves string[]
---@param kind string
---@param node_type string
---@return string?
local function join_spec(leaves, kind, node_type)
    if #leaves == 0 then
        return nil
    end
    if node_type == "import_include" and #leaves >= 2 then
        local dir = leaves[1]:gsub("/$", "")
        return dir .. "/" .. leaves[2]
    end
    return leaves[1]
end

--- The include the cursor is on, resolved.
---@param buf integer?    defaults to the current buffer
---@param row integer?    1-based line; defaults to the cursor
---@param col integer?    1-based column; defaults to the cursor
---@return { kind: string, spec: string, path: string?, tried: string[] }?
function M.include_at(buf, row, col)
    buf = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
    ---@cast buf integer
    if not api.nvim_buf_is_valid(buf) then
        return nil
    end
    if not row or not col then
        local win = fn.bufwinid(buf)
        local pos = win ~= -1 and api.nvim_win_get_cursor(win) or { 1, 0 }
        row, col = pos[1], pos[2] + 1
    end
    if not pcall(vim.treesitter.language.add, "latex") then
        return nil
    end
    -- `get_node` reads the LAST parsed tree and does not itself parse, so a buffer whose parser was
    -- only just created (no `latex` filetype plugin ran, or nothing has parsed it yet) would answer
    -- nil for every position. Parse first, then ask.
    local ok_parser, parser = pcall(vim.treesitter.get_parser, buf, "latex")
    if not ok_parser or not parser then
        return nil
    end
    pcall(function()
        parser:parse()
    end)
    local ok, node = pcall(vim.treesitter.get_node, { bufnr = buf, pos = { row - 1, col - 1 }, lang = "latex" })
    if not ok then
        return nil
    end
    local include, kind = include_ancestor(node)
    if not include or not kind then
        return nil
    end
    local spec = join_spec(target_leaves(include, buf), kind, include:type())
    if not spec then
        return nil
    end
    -- A comma list (`\addbibresource{a.bib,b.bib}`, `\bibliography{a,b}`) names several files; `gf`
    -- takes the first, which is the only one a single jump can mean.
    spec = vim.split(spec, ",", { plain = true })[1]
    local file = fn.fnamemodify(api.nvim_buf_get_name(buf), ":p")
    local root = root_mod.of(buf)
    local path, tried = M.resolve(spec, kind, M.search_dirs(kind, file, root))
    return { kind = kind, spec = spec, path = path, tried = tried }
end

--- A window a FILE may be opened in: a normal, listed, file window — never a float and never one of
--- our own panels. Every jump resolves its destination here, so a `<CR>` in the TOC can never replace
--- the TOC with the file it points at.
---@param prefer integer?  the window the panel was opened from
---@return integer?
function M.code_win(prefer)
    ---@param win integer?
    ---@return boolean
    local function usable(win)
        if not win or not api.nvim_win_is_valid(win) then
            return false
        end
        if api.nvim_win_get_config(win).relative ~= "" then
            return false -- a float
        end
        local buf = api.nvim_win_get_buf(win)
        return vim.bo[buf].buftype == ""
    end
    if usable(prefer) then
        return prefer
    end
    local current = api.nvim_get_current_win()
    if usable(current) then
        return current
    end
    for _, win in ipairs(api.nvim_list_wins()) do
        if usable(win) then
            return win
        end
    end
    return nil
end

--- Open `path` at `lnum`:`col` — the ONE jump used by the TOC, the pickers and `gf`.
---@param path string
---@param lnum integer?     1-based line (default 1)
---@param col integer?      1-based column (default 1)
---@param opts { win?: integer, cmd?: string, focus?: boolean }?
---   `win` the window to prefer, `cmd` an opening command ("edit"|"split"|"vsplit"|"tabedit"),
---   `focus` false leaves the cursor where it is (a peek).
---@return boolean
function M.open_at(path, lnum, col, opts)
    opts = opts or {}
    local target = M.code_win(opts.win)
    local from = api.nvim_get_current_win()
    if not target then
        vim.cmd("topleft split " .. fn.fnameescape(path))
        target = api.nvim_get_current_win()
    else
        api.nvim_set_current_win(target)
        vim.cmd(("%s %s"):format(opts.cmd or "edit", fn.fnameescape(path)))
        target = api.nvim_get_current_win()
    end
    pcall(api.nvim_win_set_cursor, target, { math.max(1, lnum or 1), math.max(0, (col or 1) - 1) })
    api.nvim_win_call(target, function()
        vim.cmd("normal! zz")
    end)
    if opts.focus == false and api.nvim_win_is_valid(from) then
        api.nvim_set_current_win(from)
    end
    return true
end

--- Create the file an include names but that does not exist yet (the confirmed half of `gf`), and
--- open it. Only ever offered for a TeX include: a missing graphic or `.bib` is a real error, while a
--- missing chapter is usually the next one to write.
---@param spec string
---@param buf integer
---@param cmd string?
---@return nil
local function offer_create(spec, buf, cmd)
    local file = fn.fnamemodify(api.nvim_buf_get_name(buf), ":p")
    local root = root_mod.of(buf)
    local dir = M.search_dirs("tex", file, root)[1] or fs.dirname(file)
    local path = spec:sub(1, 1) == "/" and spec or fs.normalize(dir .. "/" .. spec)
    if not path:match("%.%a+$") then
        path = path .. (config.nav.extensions.tex[2] or ".tex")
    end
    require("lvim-ui").confirm({
        title = "lvim-tex",
        prompt = ("Create %s?"):format(fn.fnamemodify(path, ":~:.")),
        callback = function(yes)
            if not yes then
                return
            end
            fn.mkdir(fs.dirname(path), "p")
            local ok = pcall(fn.writefile, {}, path)
            if not ok then
                vim.notify(("lvim-tex: could not create %s"):format(path), vim.log.levels.ERROR)
                return
            end
            M.open_at(path, 1, 1, { cmd = cmd })
        end,
    })
end

--- `gf` for TeX: jump to the include under the cursor. Falls back to the built-in `gf` when the
--- cursor is not on an include, so the key never gets worse than it was.
---@param opts { buf?: integer, cmd?: string }?
---@return boolean  whether an include was handled (false = the built-in ran)
function M.goto_file(opts)
    opts = opts or {}
    local buf = opts.buf or api.nvim_get_current_buf()
    local hit = M.include_at(buf)
    if not hit then
        -- Not on an include: run Neovim's own `gf` (no remapping, so this cannot recurse into us).
        pcall(vim.cmd, "normal! gf")
        return false
    end
    if hit.path then
        M.open_at(hit.path, 1, 1, { cmd = opts.cmd })
        return true
    end
    if hit.kind == "tex" and config.nav.create_missing then
        offer_create(hit.spec, buf, opts.cmd)
        return true
    end
    -- Naming the candidates is the difference between "it does not work" and "the extension list
    -- needs one more entry" — the tried list IS the diagnosis.
    vim.notify(
        ("lvim-tex: %q not found\n  tried:\n    %s"):format(
            hit.spec,
            table.concat(
                vim.tbl_map(function(p)
                    return fn.fnamemodify(p, ":~:.")
                end, hit.tried),
                "\n    "
            )
        ),
        vim.log.levels.WARN
    )
    return true
end

--- Install the buffer-local file-jump keymaps for `buf`.
---@param buf integer
---@return nil
function M.attach(buf)
    local keys = config.keys or {}
    ---@param lhs string|false|nil
    ---@param cmd string?
    ---@param desc string
    local function map(lhs, cmd, desc)
        if not lhs or lhs == "" then
            return
        end
        vim.keymap.set("n", lhs, function()
            M.goto_file({ buf = buf, cmd = cmd })
        end, { buffer = buf, silent = true, desc = "lvim-tex: " .. desc })
    end
    map(keys.goto_file, "edit", "open the include under the cursor")
    map(keys.goto_file_split, "split", "open the include under the cursor in a split")
    map(keys.goto_file_vsplit, "vsplit", "open the include under the cursor in a vertical split")
end

return M
