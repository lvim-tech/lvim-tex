-- lvim-tex: the treesitter access layer shared by every editing feature.
-- Text objects, motions, `%` matching and the env/command/delimiter/fraction operators all ask the
-- same three questions — "is this buffer a parsed LaTeX buffer", "what node is under the cursor" and
-- "what is the nearest ancestor of KIND" — so they are answered once, here.
--
-- Two grammar facts drive most of what follows, and both are recorded in the shipped queries as well
-- (after/queries/latex/textobjects.scm):
--   • an environment has NO `body` node — only `begin:` and `end:` fields, with the body as the run of
--     siblings between them. Anything that wants "the inside" has to name that run itself.
--   • `\left…\right` is a `math_delimiter` with four fields (left_command / left_delimiter /
--     right_command / right_delimiter); a PLAIN `(`…`)` pair has no node at all — the two parentheses
--     are anonymous sibling tokens. The delimiter toggle therefore has two code paths, not one.
--
-- The node-type SETS below mirror the query file's node lists. They are data, deliberately duplicated
-- rather than derived: a query capture cannot answer "is the node under the cursor an environment"
-- without running a query, and the motions/operators need that answer on every keystroke.
--
---@module "lvim-tex.ts"

local config = require("lvim-tex.config")

local api = vim.api
local treesitter = vim.treesitter

local M = {}

--- Filetypes of this plugin's list that parse with the `bibtex` grammar, not `latex`.
---@type table<string, boolean>
local BIBTEX_FILETYPES = { bib = true, bibtex = true }

---@type boolean  the filetype → parser mapping has been registered
local registered = false

--- Tell Neovim which parser a TeX filetype uses.
---
--- Neovim resolves a buffer's grammar from its FILETYPE, and its built-in table holds only
--- help/checkhealth — while the parser registry names the latex parser's filetype `latex`, so a
--- `tex` buffer maps to a non-existent `tex` grammar. Anything that takes the parser from the
--- filetype rather than being handed one is then dead in a TeX buffer: `vim.treesitter.foldexpr()`
--- (row S6), lvim-ts's activation (which is what applies the indents query of row S7), and
--- `vim.treesitter.start`. `language.register` is the API Neovim provides for exactly this, it is
--- idempotent, and it is registered from the plugin's own filetype list so a user who adds one gets
--- it too.
---@return nil
function M.register_languages()
    registered = true
    local tex, bib = {}, {}
    for _, ft in ipairs(config.filetypes or {}) do
        if BIBTEX_FILETYPES[ft] then
            bib[#bib + 1] = ft
        else
            tex[#tex + 1] = ft
        end
    end
    if #tex > 0 then
        pcall(treesitter.language.register, "latex", tex)
    end
    if #bib > 0 then
        pcall(treesitter.language.register, "bibtex", bib)
    end
end

--- Turn a list of node types into a lookup set.
---@param list string[]
---@return table<string, boolean>
local function set(list)
    local out = {}
    for _, name in ipairs(list) do
        out[name] = true
    end
    return out
end

--- Every environment node type the grammar produces (`\begin{x}…\end{x}`).
---@type table<string, boolean>
M.ENVIRONMENTS = set({
    "generic_environment",
    "math_environment",
    "comment_environment",
    "listing_environment",
    "verbatim_environment",
    "minted_environment",
    "pycode_environment",
    "sagesilent_environment",
    "sageblock_environment",
    "luacode_environment",
    "asy_environment",
    "asydef_environment",
})

--- Math zones: the two inline forms, display math, and the AMS-style math environments.
---@type table<string, boolean>
M.MATH = set({ "inline_formula", "displayed_equation", "math_environment" })

--- Sectioning units. A `section` node spans from its own `\section` token to just before the next
--- heading of the same or a higher level, which is what makes section motions structural.
---@type table<string, boolean>
M.SECTIONS = set({ "part", "chapter", "section", "subsection", "subsubsection", "paragraph", "subparagraph" })

--- `\left…\right` pairs — the only delimiter pair the grammar gives a node of its own.
---@type table<string, boolean>
M.DELIMITERS = set({ "math_delimiter" })

--- Brace and bracket groups. These are ARGUMENT groups as much as delimiters, which is why the
--- delimiter TOGGLE ignores them (see edit.lua) while the delimiter TEXT OBJECT accepts them.
---@type table<string, boolean>
M.GROUPS = set({
    "curly_group",
    "curly_group_author_list",
    "curly_group_command_name",
    "curly_group_glob_pattern",
    "curly_group_impl",
    "curly_group_key_value",
    "curly_group_label",
    "curly_group_label_list",
    "curly_group_path",
    "curly_group_path_list",
    "curly_group_spec",
    "curly_group_text",
    "curly_group_text_list",
    "curly_group_uri",
    "curly_group_value",
    "curly_group_word",
    "brack_group",
    "brack_group_argc",
    "brack_group_key_value",
    "brack_group_text",
    "brack_group_word",
})

--- Command node types: the catch-all `generic_command` plus every command the grammar knows by name.
--- Sectioning commands are deliberately ABSENT — `\section{…}` parses as a `section` node that owns
--- the rest of the document, so treating it as a command would make `dsc` delete a whole section.
---@type table<string, boolean>
M.COMMANDS = set({
    "generic_command",
    "class_include",
    "package_include",
    "latex_include",
    "verbatim_include",
    "graphics_include",
    "svg_include",
    "inkscape_include",
    "import_include",
    "bibtex_include",
    "bibstyle_include",
    "biblatex_include",
    "label_definition",
    "label_reference",
    "label_reference_range",
    "label_number",
    "citation",
    "hyperlink",
    "caption",
    "text_mode",
    "new_command_definition",
    "old_command_definition",
    "let_command_definition",
    "environment_definition",
    "theorem_definition",
    "paired_delimiter_definition",
    "glossary_entry_definition",
    "acronym_definition",
    "color_definition",
})

--- One `\item` entry of a list environment.
---@type table<string, boolean>
M.ITEMS = set({ "enum_item" })

--- The parser language for a buffer, or nil when the filetype maps to none.
---@param buf integer
---@return string?
function M.lang(buf)
    local ft = vim.bo[buf].filetype
    if ft == "" then
        return nil
    end
    return treesitter.language.get_lang(ft)
end

--- Is `buf` a LaTeX buffer this plugin's editing features apply to? `bib` is in the plugin's
--- filetype list for the build/diagnostics half, but it is a DIFFERENT grammar with none of the
--- nodes below, so every editing feature is gated on this. The filetype mapping is registered on
--- first use — this is the gate every feature passes through, so nothing can run before it.
---@param buf integer
---@return boolean
function M.is_latex(buf)
    if not registered then
        M.register_languages()
    end
    return M.lang(buf) == "latex"
end

--- The parsed root node of `buf`, or nil when there is no latex parser / the parse failed.
--- Parses only if the tree is out of date, so calling it per keystroke is cheap.
---@param buf integer
---@return TSNode?
function M.root(buf)
    if not api.nvim_buf_is_valid(buf) or not M.is_latex(buf) then
        return nil
    end
    -- The grammar is named explicitly (never resolved from the filetype) and loaded first, so this
    -- works in a buffer nothing has parsed yet.
    if not pcall(treesitter.language.add, "latex") then
        return nil
    end
    local ok, parser = pcall(treesitter.get_parser, buf, "latex", { error = false })
    if not ok or not parser then
        return nil
    end
    local ok_parse, trees = pcall(parser.parse, parser)
    if not ok_parse or not trees or not trees[1] then
        return nil
    end
    return trees[1]:root()
end

--- The smallest node covering a position — ANONYMOUS nodes included, because the interesting
--- tokens of LaTeX (`\begin`, `\left`, `$`, `{`) are all anonymous.
---@param buf integer
---@param row integer  0-based
---@param col integer  0-based
---@return TSNode?
function M.node_at(buf, row, col)
    local root = M.root(buf)
    if not root then
        return nil
    end
    return root:descendant_for_range(row, col, row, col)
end

--- The cursor as a 0-based (row, col) pair, plus its buffer.
---@param win integer?  window (0 / nil = current)
---@return integer buf
---@return integer row  0-based
---@return integer col  0-based
function M.cursor(win)
    win = win or 0
    local pos = api.nvim_win_get_cursor(win)
    return api.nvim_win_get_buf(win), pos[1] - 1, pos[2]
end

--- The nearest ancestor (the node itself included) whose type is in `types`.
---@param node TSNode?
---@param types table<string, boolean>
---@return TSNode?
function M.ancestor(node, types)
    while node do
        if types[node:type()] then
            return node
        end
        node = node:parent()
    end
    return nil
end

--- The nearest ancestor (the node itself included) whose type is in ANY of `sets`, together with
--- the index of the set that matched — how a `@block` capture is told apart as "math" or
--- "delimiter" without a second query.
---@param node TSNode?
---@param sets table<string, boolean>[]
---@return TSNode?  node
---@return integer? index of the matching set
function M.ancestor_any(node, sets)
    while node do
        local t = node:type()
        for i, s in ipairs(sets) do
            if s[t] then
                return node, i
            end
        end
        node = node:parent()
    end
    return nil, nil
end

--- A node's text, read from the buffer.
---@param node TSNode?
---@param buf integer
---@return string
function M.text(node, buf)
    if not node then
        return ""
    end
    return treesitter.get_node_text(node, buf) or ""
end

--- The first child of `node` carrying `field`, or nil.
---@param node TSNode?
---@param field string
---@return TSNode?
function M.field(node, field)
    if not node then
        return nil
    end
    return node:field(field)[1]
end

--- Does a 0-based range contain a 0-based position? The end is EXCLUSIVE, exactly as treesitter
--- reports it, so a position on the closing character of a node is inside it and one past is not.
---@param range integer[]  { start_row, start_col, end_row, end_col }
---@param row integer
---@param col integer
---@return boolean
function M.contains(range, row, col)
    if row < range[1] or row > range[3] then
        return false
    end
    if row == range[1] and col < range[2] then
        return false
    end
    if row == range[3] and col >= range[4] then
        return false
    end
    return true
end

--- Compare two positions.
---@param r1 integer
---@param c1 integer
---@param r2 integer
---@param c2 integer
---@return integer  -1 when the first is earlier, 0 when equal, 1 when later
function M.cmp(r1, c1, r2, c2)
    if r1 ~= r2 then
        return r1 < r2 and -1 or 1
    end
    if c1 ~= c2 then
        return c1 < c2 and -1 or 1
    end
    return 0
end

--- Rough "size" of a range, used to pick the INNERMOST of several candidates. Rows are weighted far
--- above columns so a one-line range always sorts below a multi-line one.
---@param range integer[]
---@return integer
function M.size(range)
    return (range[3] - range[1]) * 100000 + (range[4] - range[2])
end

return M
