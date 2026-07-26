-- lvim-tex: package documentation (checklist row M1) — `texdoc` for the element under the cursor.
--
-- Every TeX distribution ships the manual of every package it installs, and `texdoc` is the index
-- that finds it. What it cannot do is guess WHICH package you mean, and that is this module's whole
-- job: with the cursor inside a `\usepackage{…}` the answer is exact (the grammar splits a
-- comma list into its own nodes, so `\usepackage{amsmath,geometry}` opens the right one of the two);
-- anywhere else, the honest answer is a menu of the packages the DOCUMENT loads, which is a far
-- shorter and more useful list than everything installed.
--
-- Two things are deliberate:
--
--   • THE PACKAGE LIST IS THE PROJECT'S. `\usepackage` written in a chapter counts, because a
--     preamble may be `\input` — so the scan runs over the same file set as the TOC
--     (`structure.files`). Distribution includes are exactly what the structure model DROPS from its
--     rows (they are not places a reader navigates to), which is why the scan lives here rather than
--     re-using an entry list that deliberately omits them.
--
--   • OPENING AND RESOLVING ARE SEPARATE. `texdoc <pkg>` hands the manual to a PDF viewer — there is
--     nothing to assert and nothing to catch. `texdoc -l <pkg>` prints the files it WOULD open, so
--     health and the proofs can check that the right manual was found without a window appearing.
--     Both argv forms are built by the same function, from config.
--
---@module "lvim-tex.doc"

local config = require("lvim-tex.config")
local nav = require("lvim-tex.nav")
local root_mod = require("lvim-tex.root")
local structure = require("lvim-tex.structure")
local ts = require("lvim-tex.ts")

local ui = require("lvim-ui")

local api = vim.api
local fn = vim.fn

local M = {}

--- The pointer/separator glyph the whole ecosystem uses between the parts of one row.
local ARROW = "➤"

--- Include node types whose argument names a distribution file `texdoc` can document.
---@type table<string, boolean>
local DOCUMENTED = { package_include = true, class_include = true }

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

--- The package or class name under a position, or nil when the cursor is not inside one.
---@param buf integer?  defaults to the current buffer
---@param row integer?  0-based; defaults to the cursor
---@param col integer?  0-based; defaults to the cursor
---@return string?
function M.package_at(buf, row, col)
    local cbuf, crow, ccol = ts.cursor(0)
    buf = buf or cbuf
    row = row or crow
    col = col or ccol
    local node = ts.node_at(buf, row, col)
    local include = ts.ancestor(node, DOCUMENTED)
    if not include then
        return nil
    end
    -- The grammar gives each name in `\usepackage{a,b}` its own `path` leaf, so the one the cursor is
    -- in is the one meant. With the cursor on the command or a brace there is no leaf, and the first
    -- name is the answer.
    local first = nil
    ---@param n TSNode
    local function walk(n)
        for child in n:iter_children() do
            if child:type() == "path" then
                local name = vim.trim(ts.text(child, buf))
                if name ~= "" then
                    first = first or name
                    if ts.contains({ child:range() }, row, col) then
                        first = name
                        return true
                    end
                end
            elseif walk(child) then
                return true
            end
        end
        return false
    end
    walk(include)
    return first
end

--- Every package and class the project loads, in the order the document reads them (deduplicated).
---@param root string
---@return { name: string, kind: "package"|"class", file: string, lnum: integer }[]
function M.packages(root)
    local out, seen = {}, {}
    if not pcall(vim.treesitter.language.add, "latex") then
        return out
    end
    for _, record in ipairs(structure.files(root)) do
        if record.kind == "tex" then
            local src = nav.read(record.path)
            local ok, parser = pcall(vim.treesitter.get_string_parser, src or "", "latex")
            local tree = (src and ok and parser) and parser:parse()[1] or nil
            if tree and src then
                ---@param node TSNode
                local function walk(node)
                    local kind = node:type()
                    if DOCUMENTED[kind] then
                        local lnum = node:range() + 1
                        ---@param n TSNode
                        local function leaves(n)
                            for child in n:iter_children() do
                                if child:type() == "path" then
                                    for _, name in
                                        ipairs(
                                            vim.split(vim.treesitter.get_node_text(child, src), ",", { plain = true })
                                        )
                                    do
                                        name = vim.trim(name)
                                        if name ~= "" and not seen[name] then
                                            seen[name] = true
                                            out[#out + 1] = {
                                                name = name,
                                                kind = kind == "class_include" and "class" or "package",
                                                file = record.path,
                                                lnum = lnum,
                                            }
                                        end
                                    end
                                else
                                    leaves(child)
                                end
                            end
                        end
                        leaves(node)
                        return
                    end
                    for child in node:iter_children() do
                        walk(child)
                    end
                end
                walk(tree:root())
            end
        end
    end
    return out
end

--- The argv a documentation lookup runs. `list` builds the RESOLVING form (`-l`), which prints the
--- files texdoc would open instead of opening them.
---@param name string
---@param list boolean?
---@return string[]
function M.argv(name, list)
    local argv = { config.docs.bin }
    for _, arg in ipairs((list and config.docs.list_args or config.docs.args) or {}) do
        argv[#argv + 1] = arg
    end
    argv[#argv + 1] = name
    return argv
end

--- Which documentation files texdoc has for `name` — the `-l` form, so nothing opens.
---@param name string
---@param callback fun(files: string[], err: string?): nil
---@return nil
function M.resolve(name, callback)
    if fn.executable(config.docs.bin) ~= 1 then
        callback({}, ("%s is not on PATH"):format(config.docs.bin))
        return
    end
    vim.system(M.argv(name, true), { text = true, timeout = config.docs.timeout }, function(done)
        vim.schedule(function()
            local files = {}
            for _, line in ipairs(vim.split(done.stdout or "", "\n", { plain = true })) do
                -- `texdoc -l` prints `<n> <score> <path>`; the path is the last field, and only a
                -- readable one is a real hit.
                local path = line:match("(%S+)%s*$")
                if path and path:find("/") then
                    files[#files + 1] = path
                end
            end
            callback(files, #files == 0 and ("texdoc has no documentation for %q"):format(name) or nil)
        end)
    end)
end

--- Open `name`'s documentation. texdoc hands the file to a viewer of its own and returns at once, so
--- the child is detached: closing Neovim must not close the manual.
---@param name string
---@return nil
function M.open(name)
    if fn.executable(config.docs.bin) ~= 1 then
        notify(("%s is not on PATH"):format(config.docs.bin), vim.log.levels.WARN)
        return
    end
    -- Resolve first: texdoc's own "no documentation" goes to stderr in a detached child, where
    -- nobody would ever see it.
    M.resolve(name, function(files, err)
        if err then
            notify(err, vim.log.levels.WARN)
            return
        end
        notify(("%s %s  %s  %s"):format(config.icons.doc, name, ARROW, fn.fnamemodify(files[1], ":t")))
        vim.system(M.argv(name), { detach = true })
    end)
end

--- Pick a package from the ones the project loads, with a final row for typing any other name.
---@param root string
---@return nil
local function choose(root)
    local packages = M.packages(root)
    local items = {}
    for _, package in ipairs(packages) do
        items[#items + 1] = {
            label = ("%s  %s %s"):format(package.name, ARROW, package.kind),
            icon = package.kind == "class" and config.icons.section or config.icons.doc,
        }
    end
    items[#items + 1] = { label = "Another package…", icon = config.icons.doc }
    ui.select({
        title = ("%s Package documentation"):format(config.icons.doc),
        items = items,
        callback = function(confirmed, index)
            if not confirmed then
                return
            end
            local package = packages[index]
            if package then
                M.open(package.name)
                return
            end
            ui.input({
                title = ("%s texdoc"):format(config.icons.doc),
                callback = function(ok, value)
                    if ok and value and vim.trim(value) ~= "" then
                        M.open(vim.trim(value))
                    end
                end,
            })
        end,
    })
end

--- `:LvimTex doc [package]` / `,ld` — the manual for the package under the cursor, for one named on
--- the command line, or one picked from the packages this document loads.
---@param name string?  an explicit package name, from the command line
---@param buf integer?
---@return nil
function M.doc(name, buf)
    buf = buf or api.nvim_get_current_buf()
    name = (name and vim.trim(name) ~= "") and vim.trim(name) or M.package_at(buf)
    if name then
        M.open(name)
        return
    end
    local root = root_mod.of(buf)
    if not root then
        ui.input({
            title = ("%s texdoc"):format(config.icons.doc),
            callback = function(ok, value)
                if ok and value and vim.trim(value) ~= "" then
                    M.open(vim.trim(value))
                end
            end,
        })
        return
    end
    choose(root)
end

return M
