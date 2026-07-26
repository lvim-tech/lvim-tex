-- lvim-tex: which file IS the document, and which files belong to it.
--
-- A LaTeX project is compiled through ONE root document; every other file is pulled in by it. So
-- every action (build, view, diagnostics, TOC) resolves the root FIRST — building the chapter buffer
-- you happen to be editing would produce a document without a preamble.
--
-- The strategy chain, in order (first match wins). The order is evidence-strength, not convenience:
--   1. a `% !TEX root = …` magic comment  — the author said so explicitly; followed up to 5 hops so
--      a chapter may point at a part which points at the main file.
--   2. `\documentclass[main.tex]{subfiles}` — the subfiles package encodes its main file in the
--      optional argument, which is just as explicit (and is why step 4 must NOT run first: a subfile
--      DOES carry a \documentclass of its own).
--   3. a marker file upward (`.texlabroot`, `texlabroot`, `.latexmkrc`) — the same markers texlab
--      roots on, so the LSP and the builder can never disagree about the project.
--   4. an upward `\documentclass` scan — the current file first, then its directory, then ancestors.
--   5. the file itself, as the honest fallback.
--
-- Two things deliberately do NOT come from treesitter:
--   • the magic comments and the `\documentclass` scan are LINE reads of the first few lines. They
--     must work before any parser is installed (and on a file that is not loaded in a buffer).
--   • the REBUILD watch set comes from latexmk's own dependency list (`.fls`, then `.fdb_latexmk`),
--     because that is the only source that knows about a changed `.bib`, `.sty`, `.cls`, a generated
--     file, or an `\input` whose path was built by a macro. The treesitter include graph is for
--     NAVIGATION (TOC, gf, pickers) and is the watch-set fallback before the first build exists.
--
---@module "lvim-tex.root"

local config = require("lvim-tex.config")
local state = require("lvim-tex.state")

local api = vim.api
local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

local M = {}

-- How far up the tree the `\documentclass` scan walks before giving up.
local MAX_UPWARD = 4
-- How many magic-comment hops are followed before assuming a cycle.
local MAX_HOPS = 5
-- Extensions tried, in order, when an include names no extension.
local TEX_EXT = { "", ".tex", ".ltx" }

-- Files the BUILD writes. A rebuild must not be triggered by its own output, and when the artefacts
-- land BESIDE the source (`out_dir = false`) "is it in the out dir" cannot answer that — the out dir
-- is then the project itself. So an artefact is recognised by BEING one.
---@type table<string, boolean>
local ARTEFACT_EXT = {}
for _, ext in ipairs({
    "aux",
    "bbl",
    "bcf",
    "blg",
    "brf",
    "dvi",
    "fdb_latexmk",
    "fls",
    "fmt",
    "glg",
    "glo",
    "gls",
    "idx",
    "ilg",
    "ind",
    "lof",
    "log",
    "lot",
    "nav",
    "out",
    "pdf",
    "ps",
    "run.xml",
    "snm",
    "toc",
    "vrb",
    "xdv",
}) do
    ARTEFACT_EXT[ext] = true
end

-- Include node types of the tree-sitter-latex grammar whose target is ITSELF a TeX file, so the
-- graph scan RECURSES into it. Verified against the grammar's own highlight queries.
---@type table<string, boolean>
local RECURSIVE_INCLUDE = {
    latex_include = true, -- \input, \include, \subfile, \subfileinclude
    import_include = true, -- \import / \subimport (directory + file)
    verbatim_include = true, -- \verbatiminput and friends
}

-- Include node types whose target is a LEAF resource: it belongs to the project (so the TOC and the
-- watch set want it) but holds no further includes.
---@type table<string, boolean>
local LEAF_INCLUDE = {
    bibtex_include = true, -- \bibliography
    biblatex_include = true, -- \addbibresource
    bibstyle_include = true, -- \bibliographystyle
    graphics_include = true, -- \includegraphics
    svg_include = true,
    inkscape_include = true,
    class_include = true, -- \documentclass
    package_include = true, -- \usepackage
}

--- `buf`, with the "current buffer" shorthands (nil and 0) resolved to a real buffer number.
---@param buf integer?
---@return integer
local function resolve_buf(buf)
    if buf == nil or buf == 0 then
        return api.nvim_get_current_buf()
    end
    return buf
end

--- Absolute, symlink-resolved form of `path`, or nil when it does not exist.
---@param path string?
---@return string?
local function real(path)
    if not path or path == "" then
        return nil
    end
    local abs = fn.fnamemodify(fs.normalize(path), ":p")
    local stat = uv.fs_stat(abs)
    if not stat then
        return nil
    end
    -- `:p` keeps a trailing slash on directories; normalise it away so table keys match.
    return (abs:gsub("/$", ""))
end

--- The first `n` lines of `path` — from the LOADED buffer when there is one (so an unsaved magic
--- comment is honoured), otherwise from disk.
---@param path string
---@param n integer
---@return string[]
local function head_lines(path, n)
    local buf = fn.bufnr(path)
    if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
        return api.nvim_buf_get_lines(buf, 0, n, false)
    end
    local ok, lines = pcall(fn.readfile, path, "", n)
    return (ok and type(lines) == "table") and lines or {}
end

--- Resolve `spec` (an include/directive target, possibly extension-less and relative) against the
--- directory `dir`.
---@param spec string
---@param dir string
---@return string?  absolute path of an existing file
local function resolve(spec, dir)
    spec = vim.trim(spec):gsub('^"(.*)"$', "%1")
    if spec == "" then
        return nil
    end
    local base = spec:sub(1, 1) == "/" and spec or (dir .. "/" .. spec)
    for _, ext in ipairs(TEX_EXT) do
        local hit = real(base .. ext)
        if hit then
            return hit
        end
    end
    return nil
end

--- The `% !TEX <key> = <value>` directives in the head of `path`. Only the two directives that
--- exist in the wild are recognised — `root` (the document to compile) and `program` (the engine),
--- matched case-insensitively with either `=` or bare whitespace as the separator.
---@param path string
---@return { root?: string, program?: string }
function M.magic(path)
    local out = {}
    if not config.root.magic_comment then
        return out
    end
    for _, line in ipairs(head_lines(path, config.root.scan_lines)) do
        -- `%%` is an escaped percent in a Lua pattern; the directive itself is `% !TEX key = value`.
        -- The key may carry a hyphen because the engine directive has TWO spellings in the wild:
        -- `program` and TeXShop's `TS-program`, which is what most existing documents actually carry
        -- (`%!TEX TS-program = xelatex`). A key pattern of `[%a_]+` matched neither the hyphen nor the
        -- prefix, so such a document silently compiled with the DEFAULT engine — and a preamble with
        -- fontspec then dies on "requires either XeTeX or LuaTeX", pointing at a file in the TeX
        -- distribution. The `TS-` prefix is stripped so both spellings mean the same thing here.
        local key, value = line:match("^%s*%%+%s*!%s*TEX%s+([%a%-_]+)%s*=?%s*(.-)%s*$")
        if key then
            key = key:lower():gsub("^ts%-", "")
            if (key == "root" or key == "program") and value ~= "" then
                out[key] = value
            end
        end
    end
    return out
end

--- The engine override a `% !TEX program = …` directive asks for, as a `builders` key, or nil.
--- Only names we actually have a builder for are honoured; anything else is reported by health
--- rather than silently ignored at build time.
---@param path string
---@return string?
function M.program(path)
    local program = M.magic(path).program
    if not program then
        return nil
    end
    program = program:lower()
    if config.builders[program] then
        return program
    end
    -- `% !TEX program = xelatex|lualatex|pdflatex` names an ENGINE, not one of our backends: latexmk
    -- drives all of them, so the engine is passed through as an extra latexmk flag by build.latexmk.
    return nil
end

--- The engine name a `% !TEX program = …` directive asks for (xelatex, lualatex, …), or nil.
---@param path string
---@return string?
function M.engine(path)
    local program = M.magic(path).program
    if not program or config.builders[program:lower()] then
        return nil
    end
    return program:lower()
end

--- The backend a `% !TEX program` directive selects for this project: the compiled file's own
--- directive first (it is the more specific statement), then the ROOT's.
---
--- The root is consulted at all because the directive lives in the PREAMBLE, and a subfile has none —
--- so compiling one chapter of a book whose root says `xelatex` used to fall back to the default
--- engine and die on the first font package.
---@param root string
---@param target string?
---@return string?
function M.program_for(root, target)
    if target and target ~= root then
        local own = M.program(target)
        if own then
            return own
        end
    end
    return M.program(root)
end

--- The ENGINE a `% !TEX program` directive names (xelatex, lualatex, …) for this project — same
--- precedence as `program_for`, and for the same reason.
---@param root string
---@param target string?
---@return string?
function M.engine_for(root, target)
    if target and target ~= root then
        local own = M.engine(target)
        if own then
            return own
        end
    end
    return M.engine(root)
end

--- The main file of a subfiles document: `\documentclass[main.tex]{subfiles}` names it in the
--- optional argument.
---@param path string
---@return string?
local function subfiles_main(path)
    for _, line in ipairs(head_lines(path, 40)) do
        local opt = line:match("^%s*\\documentclass%s*%[(.-)%]%s*{%s*subfiles%s*}")
        if opt then
            return resolve(opt, fs.dirname(path))
        end
    end
    return nil
end

--- Does `path` declare a document class (i.e. can it be compiled on its own)?
---@param path string
---@return boolean
local function has_documentclass(path)
    for _, line in ipairs(head_lines(path, 40)) do
        if line:match("^%s*\\documentclass") then
            return true
        end
    end
    return false
end

--- The `.tex` file in `dir` that looks like a root: one that declares a document class, preferring
--- the conventional names so a project with several candidates resolves deterministically.
---@param dir string
---@return string?
local function root_in_dir(dir)
    local files = fn.glob(dir .. "/*.tex", false, true)
    if #files == 0 then
        return nil
    end
    table.sort(files)
    local preferred = { "main.tex", "root.tex", "index.tex", "document.tex", "thesis.tex" }
    for _, name in ipairs(preferred) do
        for _, file in ipairs(files) do
            if fs.basename(file) == name and has_documentclass(file) then
                return real(file)
            end
        end
    end
    for _, file in ipairs(files) do
        if has_documentclass(file) then
            return real(file)
        end
    end
    return nil
end

--- Run the strategy chain for `path` (an absolute .tex path).
---@param path string
---@return string  the root document (never nil — falls back to `path` itself)
local function detect(path)
    -- 1. magic root comments, followed transitively.
    local current, seen = path, { [path] = true }
    for _ = 1, MAX_HOPS do
        local target = M.magic(current).root
        local hit = target and resolve(target, fs.dirname(current)) or nil
        if not hit or seen[hit] then
            break
        end
        seen[hit] = true
        current = hit
    end
    if current ~= path then
        return current
    end

    -- 2. the subfiles package names its main file explicitly.
    if config.root.subfiles == "root" then
        local main = subfiles_main(path)
        if main then
            return main
        end
    end

    -- 3. a marker file upward pins the project directory; the root is the document inside it.
    local marker = fs.find(config.root.markers, { upward = true, path = fs.dirname(path), type = "file" })[1]
    if marker then
        local hit = root_in_dir(fs.dirname(marker))
        if hit then
            return hit
        end
    end

    -- 4. upward \documentclass scan — this file, then its directory, then ancestors.
    if has_documentclass(path) then
        return path
    end
    local dir = fs.dirname(path)
    for _ = 1, MAX_UPWARD do
        local hit = root_in_dir(dir)
        if hit then
            return hit
        end
        local parent = fs.dirname(dir)
        if not parent or parent == dir then
            break
        end
        dir = parent
    end

    -- 5. the file itself.
    return path
end

--- The root document for `buf` (cached per buffer).
---@param buf integer?  defaults to the current buffer
---@return string?  absolute path, or nil for a buffer with no file on disk
function M.of(buf)
    buf = resolve_buf(buf)
    local cached = state.buf_root[buf]
    if cached then
        return cached
    end
    local name = api.nvim_buf_get_name(buf)
    if name == "" then
        return nil
    end
    local path = real(name) or fn.fnamemodify(fs.normalize(name), ":p")
    local root = detect(path)
    state.buf_root[buf] = root
    return root
end

--- The file the next build should compile: the project's current target, which is the root unless
--- the user toggled it to the subfile they are editing (`:LvimTex main`).
---@param buf integer?
---@return string?
function M.target(buf)
    local root = M.of(buf)
    if not root then
        return nil
    end
    return state.project(root).target
end

--- Toggle the compile target between the root document and `buf`'s own file, and return the new
--- target. Session-sticky per project: it survives until toggled back or `:LvimTex reload`.
---@param buf integer?
---@return string?  the new target
function M.toggle_target(buf)
    buf = resolve_buf(buf)
    local root = M.of(buf)
    if not root then
        return nil
    end
    local project = state.project(root)
    local self_path = real(api.nvim_buf_get_name(buf))
    if not self_path then
        return project.target
    end
    project.target = (project.target == root and self_path ~= root) and self_path or root
    return project.target
end

--- Where the build writes its artefacts.
---
--- With `config.out_dir` set, it is that path resolved against the ROOT's directory (an absolute
--- setting is used as-is) — one build directory for the whole project. With `out_dir = false` the
--- artefacts land beside the source, and "the source" is the file the ENGINE RUNS ON: every backend's
--- `cwd` is the TARGET's directory, so a toggled subfile writes its `.pdf`/`.log` next to itself, not
--- next to the root. Passing the target is therefore not optional bookkeeping — it is the difference
--- between finding the log and not.
---
--- (`false` and not `nil`, because a nil value in a Lua table is an absent key and merges nothing.) Every consumer —
--- the builder's out-dir flag, the log reader, the `.fls` watch set — must agree on this one answer,
--- which is why it lives here rather than in the build module.
---@param root string
---@param target string?  the file being compiled; defaults to `root`
---@return string
function M.out_dir(root, target)
    -- Where the ENGINE runs, which is every backend's `cwd`: the target's own directory. This is the
    -- answer whenever the artefacts are not being redirected, and it is why the target matters — a
    -- toggled subfile writes beside ITSELF, not beside the root.
    local engine_dir = fs.dirname(target or root)
    local out = config.out_dir
    if not out or out == "" then
        return engine_dir
    end
    -- A backend that CANNOT redirect its output (arara reads its whole workflow from the document and
    -- has no output-directory option at all) also writes where it runs. The alternative is worse than a
    -- wrong answer: the log parser, `M.pdf` and forward search would all look into an empty `build/`
    -- while the files sit beside the source, and the build would look successful with no PDF.
    local builder = M.program_for(root, target) or config.builder
    local ok_mod, mod = pcall(require, "lvim-tex.build." .. builder)
    if ok_mod and type(mod) == "table" and mod.supports and mod.supports.out_dir == false then
        return engine_dir
    end
    if out:sub(1, 1) == "/" then
        return out
    end
    -- A CONFIGURED out dir is one directory for the whole PROJECT, so it hangs off the ROOT — not off
    -- whichever file happens to be the target, which would scatter a `build/` into every chapter
    -- folder. The engine is told about it with `-outdir`, so its own cwd does not matter here.
    return fs.normalize(fs.dirname(root) .. "/" .. out)
end

--- The PDF the build for `root` produces when compiling `target`.
---
--- Named after the TARGET, not the root: `:LvimTex main` compiles the subfile you are in, and every
--- engine names its output after the file it was handed. It sits in the out dir for the same reason
--- the log does. Like `out_dir`, this is the ONE answer — the viewer layer, health and the SyncTeX
--- calls must not each derive it themselves.
---@param root string
---@param target string?  defaults to `root`
---@return string
function M.pdf(root, target)
    local jobname = fn.fnamemodify(target or root, ":t:r")
    return fs.normalize(M.out_dir(root, target) .. "/" .. jobname .. ".pdf")
end

--- Every file `path` pulls in, one level deep, as `{ path = <abs>, recurse = <boolean> }` records.
--- Uses the latex grammar; returns nil (not an empty list) when the parser is unavailable, so the
--- caller can tell "no includes" from "cannot know".
---@param path string
---@return { path: string, recurse: boolean }[]?
local function includes_of(path)
    local ok_lang = pcall(vim.treesitter.language.add, "latex")
    if not ok_lang then
        return nil
    end
    local ok_read, lines = pcall(fn.readfile, path)
    if not ok_read or type(lines) ~= "table" then
        return {}
    end
    local src = table.concat(lines, "\n")
    local ok_parser, parser = pcall(vim.treesitter.get_string_parser, src, "latex")
    if not ok_parser or not parser then
        return nil
    end
    local tree = parser:parse()[1]
    if not tree then
        return {}
    end

    local dir = fs.dirname(path)
    local out, seen = {}, {}

    --- Record every target leaf under `node`, resolved against `dir`. The grammar uses TWO leaf
    --- types: `path` for ordinary includes, and `glob_pattern` for `\addbibresource`, whose argument
    --- is formally a glob. Verified against the grammar's own parse tree.
    ---@param node TSNode
    ---@param recurse boolean
    local function collect(node, recurse)
        for child in node:iter_children() do
            local kind = child:type()
            if kind == "path" or kind == "glob_pattern" then
                local hit = resolve(vim.treesitter.get_node_text(child, src), dir)
                if hit and not seen[hit] then
                    seen[hit] = true
                    out[#out + 1] = { path = hit, recurse = recurse }
                end
            else
                collect(child, recurse)
            end
        end
    end

    --- Walk the whole tree looking for include nodes.
    ---@param node TSNode
    local function walk(node)
        local kind = node:type()
        if RECURSIVE_INCLUDE[kind] then
            collect(node, true)
            return
        elseif LEAF_INCLUDE[kind] then
            collect(node, false)
            return
        end
        for child in node:iter_children() do
            walk(child)
        end
    end

    walk(tree:root())
    return out
end

--- Every file belonging to the project rooted at `root`, the root itself first. Cached on the
--- project record; `state.reset()` (`:LvimTex reload`) drops it.
---@param root string
---@param force boolean?  rescan even when a cache exists
---@return string[]
function M.graph(root, force)
    local project = state.project(root)
    if project.graph and not force then
        return project.graph
    end
    local out, seen = { root }, { [root] = true }
    local queue = { root }
    while #queue > 0 do
        local current = table.remove(queue, 1)
        for _, inc in ipairs(includes_of(current) or {}) do
            if not seen[inc.path] then
                seen[inc.path] = true
                out[#out + 1] = inc.path
                if inc.recurse then
                    queue[#queue + 1] = inc.path
                end
            end
        end
    end
    project.graph = out
    return out
end

--- The files a rebuild should watch. latexmk records every file the last run actually READ in
--- `<jobname>.fls` (and `.fdb_latexmk`), which is the only list that covers a changed `.bib`,
--- `.sty`, `.cls`, a generated file or a macro-built `\input`. Before the first successful build
--- there is no such list, so the include graph stands in.
---
--- Two directories are involved and they are NOT the same: the `.fls` FILE lives wherever the build
--- wrote it (`log_dir`), while the relative paths INSIDE it are recorded against the directory the
--- engine ran in — the target's own directory. Conflating the two silently produced paths like
--- `build/chapters/ch1.tex`, which match no buffer.
---@param root string       the project's root document (owns the include-graph fallback and the cache)
---@param target string     the compiled file (the root, or the subfile when the target was toggled)
---@param log_dir string?   where the build wrote its artefacts (nil = beside the target)
---@return string[]
function M.watch(root, target, log_dir)
    local jobname = fs.basename(fn.fnamemodify(target, ":r"))
    local base_dir = fs.dirname(target)
    local artefact_dir = log_dir or base_dir
    local seen, out = {}, {}

    --- Should `path` be watched? A TeX distribution's own files change when the distribution is
    --- upgraded, not while editing, and a GENERATED artefact (`.aux`, `.bbl`, …) is written BY the
    --- build — watching either would only cost rebuilds.
    ---
    --- Two independent tests, and both are needed. An artefact is recognised by its EXTENSION, which
    --- is the only test that works when the artefacts land beside the source: with `out_dir = false`
    --- the artefact directory IS the project, so a directory test would exclude every source file in
    --- it and leave the watch set empty. The directory test then still earns its place for a SEPARATE
    --- out dir, where it also catches generated inputs with source-like extensions (a `.tex` written
    --- by the build).
    ---@param path string?
    ---@return boolean
    local function wanted(path)
        if not path or seen[path] then
            return false
        end
        if path:match("^/usr/") or path:match("/texmf") then
            return false
        end
        local name = fs.basename(path):lower()
        -- `.run.xml` is two-part, so match the longest suffix first.
        if ARTEFACT_EXT[name:match("%.([%w]+%.[%w]+)$") or ""] or ARTEFACT_EXT[name:match("%.([%w]+)$") or ""] then
            return false
        end
        if artefact_dir ~= base_dir and vim.startswith(path, artefact_dir .. "/") then
            return false
        end
        return true
    end

    --- Add `spec`, resolved against the run's directory.
    ---@param spec string?
    ---@return nil
    local function add(spec)
        local hit = spec and resolve(spec, base_dir) or nil
        if wanted(hit) then
            ---@cast hit string
            seen[hit] = true
            out[#out + 1] = hit
        end
    end

    -- The `.fls` records what the ENGINE read: sources, classes, packages, images.
    local fls = real(artefact_dir .. "/" .. jobname .. ".fls")
    for _, line in ipairs(fls and fn.readfile(fls) or {}) do
        add(line:match("^INPUT%s+(.+)$"))
    end

    -- The `.fdb_latexmk` records what EVERY latexmk rule read, which is the only place a `.bib`
    -- appears: bibliography files are read by biber, never by the engine, so they are absent from the
    -- `.fls` entirely. The two files are complementary, not one a fallback for the other. A source
    -- entry is an indented quoted path FOLLOWED by its mtime; an indented path with nothing after it
    -- is that rule's OUTPUT and is skipped.
    local fdb = real(artefact_dir .. "/" .. jobname .. ".fdb_latexmk")
    for _, line in ipairs(fdb and fn.readfile(fdb) or {}) do
        add(line:match('^%s+"([^"]+)"%s+[%d%.]+'))
    end

    if #out > 0 then
        table.sort(out)
        state.project(root).watch = out
        return out
    end
    -- No build has run yet, so the include graph is all we know.
    return M.graph(root)
end

return M
