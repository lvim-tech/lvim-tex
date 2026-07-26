-- lvim-tex: completion — what texlab already answers, and the narrow strip it does not.
--
-- COMPLETION IS NOT THIS PLUGIN'S JOB. lvim-lang wires texlab, texlab reads the project, and
-- lvim-cmp shows what it says: citation keys from every bibliography the document loads, `\label`
-- keys with the kind of thing they label, commands and environments with the `.sty` they come from,
-- package and class names from the whole TeX tree with their catalogue description, glossary and
-- acronym keys, and file paths for every include command. All of it cross-file, all of it live. That
-- was MEASURED against a multi-file, multi-bib fixture before a line of this file was written
-- (`.claude/lvim-tex/fixtures/completion.lua`), because the plan's completion rows are a
-- verification, not a feature.
--
-- What the measurement also found is a short list of commands texlab's providers do not recognise,
-- each of which a user coming from the plugin this one replaces DID have completed:
--
--   • the `\glsentry…` family and `\glsxtrshort` / `\glsxtrlong` / `\glsadd` — every other `\gls…`
--     and `\acr…` command completes, these do not;
--   • `\nameref`, `\cpageref`, `\autopageref`, `\vpageref`, `\subref` — every other reference
--     command completes, these do not;
--   • `\Citep` / `\Citet` — natbib's capitalised forms, where the lower-case ones complete.
--
-- So this module is a GAP-FILL and nothing more, and it is built so it can never become a second
-- opinion on something texlab answers:
--
--   • it registers ONE lvim-cmp source, whose config carries `fallback_for = { "lsp" }` — lvim-cmp
--     runs a fallback source only after every server it falls back for has answered with NOTHING.
--     The command lists below decide WHERE we look; the engine decides whether we are needed. The
--     day texlab learns `\nameref`, this source stops firing on it without an edit here.
--   • the data is the document model's, not a second scan: labels come from `structure.labels()`,
--     citations from `cite.entries()` (so a key's summary reads identically in the completion popup
--     and in the `,lz` action menu). Only the GLOSSARY has no model yet — the grammar's
--     `glossary_entry_definition` / `acronym_definition` nodes are scanned here, and that scan
--     belongs in `lvim-tex.structure` the next time that file is opened.
--
---@module "lvim-tex.completion"

local config = require("lvim-tex.config")
local nav = require("lvim-tex.nav")
local root_mod = require("lvim-tex.root")
local structure = require("lvim-tex.structure")

local api = vim.api
local fn = vim.fn

local M = {}

--- LSP `CompletionItemKind` values the items carry (the menu's right column reads them).
local KIND = { REFERENCE = 18, KEYWORD = 14, TEXT = 1 }

--- Node types that DEFINE a glossary entry, and where in them the key sits. `\newglossaryentry` and
--- `\newacronym` have dedicated nodes; the glossaries-extra spellings are generic commands, matched
--- by name (`config.completion.glossary_definitions`).
---@type table<string, string>
local DEFINITION = { glossary_entry_definition = "glossary", acronym_definition = "acronym" }

--- Every glossary entry and acronym the project defines, keyed by its key.
---
--- `\loadglsentries{file}` is followed, because a glossary is very often a file of its own that the
--- preamble loads — and the include graph does not know that command (it is a generic command to the
--- grammar, not an include).
---@param root string
---@return { key: string, kind: string, detail: string, file: string, lnum: integer }[]
function M.glossary(root)
    local out, seen = {}, {}
    if not pcall(vim.treesitter.language.add, "latex") then
        return out
    end
    local definitions = {}
    for _, name in ipairs(config.completion.glossary_definitions or {}) do
        definitions[name] = true
    end
    local loaders = {}
    for _, name in ipairs(config.completion.glossary_loaders or {}) do
        loaders[name] = true
    end

    local files = {}
    for _, record in ipairs(structure.files(root)) do
        if record.kind == "tex" then
            files[#files + 1] = record.path
        end
    end

    local visited = {}
    local index = 1
    while index <= #files do
        local path = files[index]
        index = index + 1
        if not visited[path] then
            visited[path] = true
            local src = nav.read(path)
            local ok, parser = pcall(vim.treesitter.get_string_parser, src or "", "latex")
            local tree = (src and ok and parser) and parser:parse()[1] or nil
            if tree and src then
                --- One braced group's text, braces stripped and whitespace collapsed.
                ---@param node TSNode?
                ---@return string
                local function text_of(node)
                    if not node then
                        return ""
                    end
                    local text = vim.treesitter.get_node_text(node, src)
                    return vim.trim((text:gsub("^{", ""):gsub("}$", ""):gsub("%s+", " ")))
                end

                --- The braced groups a definition owns, in order.
                ---
                --- A well-formed definition is ONE node and they are its children. A trailing comma
                --- inside the key-value list (`description={…},}` — which glossaries accepts and
                --- people write) makes the grammar give the node up as an ERROR, and then the
                --- command TOKEN and its groups are loose siblings instead. Reading the groups that
                --- FOLLOW the token covers both shapes with the same code, and still comes from the
                --- parse tree rather than from a pattern over the text.
                ---@param node TSNode   the definition node, or its command token
                ---@param siblings boolean  read the groups after `node` instead of inside it
                ---@return string[]
                local function groups(node, siblings)
                    local out_groups = {}
                    if siblings then
                        local sibling = node:next_sibling()
                        while sibling do
                            local kind = sibling:type()
                            if kind:find("^curly_group") then
                                out_groups[#out_groups + 1] = text_of(sibling)
                            elseif not kind:find("^brack_group") then
                                break -- the definition's arguments have ended
                            end
                            sibling = sibling:next_sibling()
                        end
                    else
                        for child in node:iter_children() do
                            if child:type():find("^curly_group") then
                                out_groups[#out_groups + 1] = text_of(child)
                            end
                        end
                    end
                    return out_groups
                end

                --- Record one definition.
                ---@param kind string
                ---@param node TSNode
                ---@param args string[]
                local function emit(kind, node, args)
                    local key = args[1] or ""
                    if key == "" or seen[key] then
                        return
                    end
                    seen[key] = true
                    local row = node:range()
                    -- An acronym's LONG form is its third argument (`\newacronym{key}{TUG}{TeX Users
                    -- Group}`); the short form stands in when there is no long one.
                    local detail = (kind == "acronym") and (args[3] ~= "" and args[3] or args[2] or "") or ""
                    out[#out + 1] = { key = key, kind = kind, detail = detail or "", file = path, lnum = row + 1 }
                end

                --- The definition kind a COMMAND NAME opens, or nil.
                ---@param name string   without the leading backslash
                ---@return string?
                local function kind_of(name)
                    if name == "newglossaryentry" then
                        return "glossary"
                    elseif name == "newacronym" then
                        return "acronym"
                    elseif definitions[name] then
                        return (name:find("acronym") or name:find("abbreviation")) and "acronym" or "glossary"
                    end
                    return nil
                end

                ---@param node TSNode
                local function walk(node)
                    local type_ = node:type()
                    local structured = DEFINITION[type_]
                    if structured then
                        emit(structured, node, groups(node, false))
                        return
                    end
                    -- A command token: `\newglossaryentry` is an anonymous node of that exact name,
                    -- and a generic command's head is a `command_name` leaf.
                    local name = nil
                    if type_:sub(1, 1) == "\\" then
                        name = type_:sub(2)
                    elseif type_ == "command_name" then
                        name = vim.treesitter.get_node_text(node, src):gsub("^\\", "")
                    end
                    if name then
                        if loaders[name] then
                            -- Another file of entries: resolve it as a TeX include and scan it too.
                            local parent = node:parent()
                            local args = (type_ == "command_name" and parent) and groups(parent, false)
                                or groups(node, true)
                            local spec = args[1] or ""
                            local target = spec ~= "" and nav.resolve(spec, "tex", nav.search_dirs("tex", path, root))
                                or nil
                            if target then
                                files[#files + 1] = target
                            end
                            return
                        end
                        local kind = kind_of(name)
                        if kind then
                            local parent = node:parent()
                            local args = (type_ == "command_name" and parent) and groups(parent, false)
                                or groups(node, true)
                            emit(kind, node, args)
                            return
                        end
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

--- The command whose braced argument encloses byte offset `upto` in `line`, plus the byte index the
--- ARGUMENT's current item starts at (after the last `{` or `,`).
---
--- Scanning text rather than the parse tree is deliberate: at the moment completion is asked for, the
--- argument is half-typed and the tree around it is broken — `\nameref{sec` has no
--- `curly_group_text`, only an error node. The scan is trivially exact because a completion argument
--- never spans a line.
---@param line string
---@param upto integer  byte offset the cursor sits at (0-based, i.e. #prefix)
---@return string? command, integer? token_start  0-based byte index of the item being typed
function M.command_at(line, upto)
    local before = line:sub(1, upto)
    -- The innermost UNCLOSED "{" left of the cursor.
    local depth, open = 0, nil
    for i = #before, 1, -1 do
        local char = before:sub(i, i)
        if char == "}" and before:sub(i - 1, i - 1) ~= "\\" then
            depth = depth + 1
        elseif char == "{" and before:sub(i - 1, i - 1) ~= "\\" then
            if depth == 0 then
                open = i
                break
            end
            depth = depth - 1
        end
    end
    if not open then
        return nil, nil
    end
    -- Optional arguments sit between the command and its group: `\cite[see][p.~3]{`.
    local head = before:sub(1, open - 1)
    while true do
        local shorter = head:match("^(.*)%b[]%s*$")
        if not shorter or shorter == head then
            break
        end
        head = shorter
    end
    local command = head:match("\\([%a@]+%*?)%s*$")
    if not command then
        return nil, nil
    end
    -- A comma list completes its LAST item; leading blanks after the comma are not part of the key.
    local item = before:sub(open + 1)
    local start = open
    local last = item:match(".*(),") -- 1-based index of the LAST comma within the argument
    if last then
        start = open + last
    end
    while before:sub(start + 1, start + 1) == " " do
        start = start + 1
    end
    return command, start
end

--- Which gap-fill data set a command wants, or nil when it is none of ours.
---@param command string?
---@return string?  "citations" | "labels" | "glossary"
function M.kind_for(command)
    if not command then
        return nil
    end
    for kind, commands in pairs(config.completion.commands or {}) do
        for _, name in ipairs(commands) do
            if name == command then
                return kind
            end
        end
    end
    return nil
end

--- The completion items for one data set, LSP-shaped (`label` / `filterText` / `documentation`), so
--- they render in the menu exactly like a server's.
---@param kind string  "citations" | "labels" | "glossary"
---@param root string
---@return { label: string, filter: string, detail: string, kind: integer }[]
function M.items(kind, root)
    local out = {}
    if kind == "citations" then
        -- `cite` is required HERE, not hoisted: it owns the action menu and therefore pulls in
        -- lvim-ui, while this module is loaded from `setup()` — hoisting it would make the whole
        -- plugin unloadable without the UI layer, just to read bibliography data. The real seam is
        -- that `entries`/`summary` belong beside the rest of the document model in `structure.lua`
        -- (findings `P9-9`), and that consolidation removes this require entirely.
        local cite = require("lvim-tex.cite")
        for key, entry in pairs(cite.entries(root)) do
            out[#out + 1] = {
                label = key,
                -- The summary joins the fuzzy-matchable text, so "companion" finds the entry whose
                -- KEY is `mittelbach2004companion` and also the one whose TITLE says it.
                filter = ("%s %s"):format(key, cite.summary(entry)),
                detail = cite.summary(entry),
                kind = KIND.REFERENCE,
            }
        end
        table.sort(out, function(a, b)
            return a.label < b.label
        end)
    elseif kind == "labels" then
        for _, label in ipairs(structure.labels(root)) do
            out[#out + 1] = {
                label = label.key,
                filter = ("%s %s"):format(label.key, label.context or ""),
                detail = label.context or "",
                kind = KIND.REFERENCE,
            }
        end
    elseif kind == "glossary" then
        for _, entry in ipairs(M.glossary(root)) do
            out[#out + 1] = {
                label = entry.key,
                filter = ("%s %s"):format(entry.key, entry.detail),
                detail = entry.detail ~= "" and entry.detail or entry.kind,
                kind = KIND.KEYWORD,
            }
        end
    end
    return out
end

--- Convert a byte column to the character index a `textEdit` range needs. lvim-cmp reads a non-LSP
--- item's range with the default utf-16 encoding, so the conversion has to be the same one.
---@param line string
---@param col integer  0-based byte column
---@return integer
local function char_col(line, col)
    local ok, index = pcall(vim.str_utfindex, line, "utf-16", col)
    return ok and index or col
end

--- The lvim-cmp source. It answers only inside one of the configured commands, and (through its
--- `fallback_for` config) only when the language server answered with nothing at all.
---@type LvimCmpSource
M.source = {
    name = "tex",

    --- Is the cursor inside a command this source serves?
    ---@param ctx LvimCmpContext
    ---@return boolean
    enabled = function(ctx)
        if not config.completion.enabled then
            return false
        end
        if not vim.tbl_contains(config.filetypes, vim.bo[ctx.bufnr].filetype) then
            return false
        end
        local command = M.command_at(ctx.line, ctx.cursor[2])
        return M.kind_for(command) ~= nil
    end,

    --- `{` opens a context so `\nameref{` completes with nothing typed yet; `,` does the same for
    --- the next key of a list.
    ---@param bufnr integer
    ---@return table<string, boolean>
    trigger_chars = function(bufnr)
        local out = {}
        if vim.tbl_contains(config.filetypes, vim.bo[bufnr].filetype) then
            for _, char in ipairs(config.completion.trigger_chars or {}) do
                out[char] = true
            end
        end
        return out
    end,

    ---@param ctx LvimCmpContext
    ---@param callback fun(items: LvimCmpItem[], incomplete: boolean)
    ---@return fun()?
    get = function(ctx, callback)
        local items = {}
        local command, start = M.command_at(ctx.line, ctx.cursor[2])
        local kind = M.kind_for(command)
        local root = kind and root_mod.of(ctx.bufnr) or nil
        if kind and root and start then
            local row = ctx.cursor[1] - 1
            local from = char_col(ctx.line, start)
            local to = char_col(ctx.line, ctx.cursor[2])
            for _, entry in ipairs(M.items(kind, root)) do
                items[#items + 1] = {
                    raw = {
                        label = entry.label,
                        detail = entry.detail ~= "" and entry.detail or nil,
                        -- The range starts at the KEY, not at lvim-cmp's keyword bounds: a key like
                        -- `sec:intro` breaks at the colon, so without this the accepted text would
                        -- land as `sec:sec:intro`.
                        textEdit = {
                            newText = entry.label,
                            range = {
                                start = { line = row, character = from },
                                ["end"] = { line = row, character = to },
                            },
                        },
                    },
                    source_name = "tex",
                    label = entry.label,
                    filter_text = entry.filter,
                    sort_text = entry.label,
                    kind = entry.kind,
                }
            end
        end
        vim.schedule(function()
            callback(items, false)
        end)
        return nil
    end,
}

--- Register the gap-fill source with lvim-cmp. A no-op (reported, not fatal) when lvim-cmp is not
--- installed — completion then is whatever the user's own engine makes of texlab, which is still
--- every row of the checklist but the three families above.
---@return boolean registered, string? err
function M.setup()
    if not config.completion.enabled then
        return false, "completion.enabled = false"
    end
    local ok, cmp = pcall(require, "lvim-cmp")
    if not ok or type(cmp.register_source) ~= "function" then
        return false, "lvim-cmp is not installed"
    end
    cmp.register_source(M.source, {
        enabled = true,
        priority = config.completion.priority,
        fallback_for = config.completion.fallback_for,
        min_keyword_length = 0,
    })
    return true, nil
end

--- Which commands this source serves, grouped by data set — health prints it, so "why does
--- `\nameref` complete but `\zref` not" has an answer that is not the source code.
---@return table<string, string[]>
function M.served()
    local out = {}
    for kind, commands in pairs(config.completion.commands or {}) do
        out[kind] = vim.deepcopy(commands)
        table.sort(out[kind])
    end
    return out
end

--- Is texlab actually attached to `buf`? The completion rows are DELEGATED, so the honest health
--- answer is whether the server that owns them is there — this is what health asks.
---@param buf integer?
---@return boolean attached, string? name
function M.server(buf)
    buf = buf or api.nvim_get_current_buf()
    for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
        if client.name:lower():find("texlab", 1, true) then
            return true, client.name
        end
    end
    return false, nil
end

--- Whether the texlab binary exists at all (health uses it to tell "not installed" from
--- "installed but not attached to this buffer").
---@return boolean
function M.server_installed()
    if fn.executable("texlab") == 1 then
        return true
    end
    return fn.executable(fn.expand("~/.local/share/nvim/lvim-pkgs/bin/texlab")) == 1
end

return M
