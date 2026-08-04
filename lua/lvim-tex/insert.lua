-- lvim-tex.insert: close the innermost OPEN environment or delimiter from insert mode (row E8).
--
-- `]]` while typing writes the `\end{…}` that belongs to whatever is still open above the cursor —
-- the one editing operator that runs mid-word, which is why it lives here and not in `lvim-tex.edit`
-- (that file owns the normal-mode operators over COMPLETE constructs).
--
-- "Open" is a question the parse tree answers exactly, and that is the whole design. Measured against
-- the latex grammar (2026-07-26):
--
--   • `\begin{x}` WITH its `\end{x}` is a single `generic_environment` node carrying both fields;
--   • `\begin{x}` WITHOUT one cannot form that node, so the grammar's error recovery leaves the
--     `begin` node as a child of an `ERROR` node;
--   • `\left(` … `\right)` is a `math_delimiter` with four fields; an unmatched `\left` is likewise a
--     bare anonymous token inside an `ERROR`.
--
-- So an OPEN construct is exactly "a `begin` node (or a `\left` token) whose parent does not close
-- it", and the innermost one is the LAST such node before the cursor in document order. Nothing is
-- counted, no text is scanned, and the two cases a text scanner gets wrong come out right for free:
-- a `\begin` inside a verbatim body or a comment is not a `begin` node at all, and standing inside a
-- COMPLETE environment offers nothing to close (there is no unmatched opener) instead of writing a
-- second `\end`.
--
-- The walk descends only into nodes that CONTAIN the cursor or that carry an error, because a
-- well-formed subtree ending before the cursor is balanced by definition — so the cost is a short
-- path down the tree, not a document scan.
--
---@module "lvim-tex.insert"

local config = require("lvim-tex.config")
local ts = require("lvim-tex.ts")

local api = vim.api

local M = {}

--- The anonymous token that opens a sized-delimiter pair. `\left` is the only one the grammar emits
--- on its own; the sized modifiers (`\bigl` …) are ordinary commands and pair by convention, not by
--- structure, so they are not tracked.
local LEFT = "\\left"

--- Does this `begin` node lack its `\end`? A closed pair is an environment NODE carrying both fields,
--- so "my parent has no `end` field" is the complete test — including the parent being an `ERROR`.
---@param node TSNode  a `begin` node
---@return boolean
local function begin_is_open(node)
    local parent = node:parent()
    if not parent then
        return true
    end
    return parent:field("end")[1] == nil
end

--- Does this `\left` token lack its `\right`? Same test one field over.
---@param node TSNode  a `\left` token
---@return boolean
local function left_is_open(node)
    local parent = node:parent()
    if not parent then
        return true
    end
    return parent:field("right_command")[1] == nil
end

--- The environment name a `begin` node declares (`\begin{itemize}` → `itemize`), or nil.
---@param node TSNode
---@param buf integer
---@return string?
local function begin_name(node, buf)
    for child in node:iter_children() do
        if child:type():match("^curly_group") then
            local text = ts.text(child, buf)
            local name = text:match("^{(.-)}$")
            if name and name ~= "" then
                return name
            end
        end
    end
    return nil
end

--- The delimiter a `\left` token opens (`\left(` → `(`), read from the token that follows it.
---@param node TSNode
---@param buf integer
---@return string?
local function left_delimiter(node, buf)
    local sibling = node:next_sibling()
    if not sibling then
        return nil
    end
    local text = vim.trim(ts.text(sibling, buf))
    return text ~= "" and text or nil
end

--- Open → close for `\left`/`\right`: the nestable pairs the delimiter TOGGLE already defines
--- (`edit.delimiters`), plus `edit.close_delimiters` — the ones that exist only to be closed because
--- they cannot be toggled (a symmetric `|…|` cannot be nested unambiguously, `\lgroup` is too rare to
--- cycle). Both are config, so a distribution-specific pair is one line away.
---@return table<string, string>
local function closers()
    local out = {}
    for _, pair in ipairs(config.edit.delimiters or {}) do
        out[pair[1]] = pair[2]
    end
    for _, pair in ipairs(config.edit.close_delimiters or {}) do
        out[pair[1]] = pair[2]
    end
    return out
end

---@class LvimTexOpenConstruct
---@field kind      "environment"|"delimiter"
---@field name      string?   environment: its name
---@field delimiter string?   delimiter: the character/command `\left` opened
---@field row       integer   0-based row of the opener
---@field col       integer   0-based column of the opener
---@field text      string    the text that closes it (`\end{itemize}`, `\right)`)

--- The innermost construct still open at (row, col), or nil when everything before it is closed.
---@param buf integer
---@param row integer  0-based
---@param col integer  0-based
---@return LvimTexOpenConstruct?
function M.open_construct(buf, row, col)
    local root = ts.root(buf)
    if not root then
        return nil
    end
    local found = nil
    local close_map = closers()

    ---@param node TSNode
    local function walk(node)
        for child in node:iter_children() do
            local sr, sc, er, ec = child:range()
            if ts.cmp(sr, sc, row, col) >= 0 then
                break -- children are ordered: nothing from here on starts before the cursor
            end
            local kind = child:type()
            if kind == "begin" and begin_is_open(child) then
                local name = begin_name(child, buf)
                if name then
                    found = {
                        kind = "environment",
                        name = name,
                        row = sr,
                        col = sc,
                        text = ("\\end{%s}"):format(name),
                    }
                end
            elseif kind == LEFT and left_is_open(child) then
                local delimiter = left_delimiter(child, buf)
                local closer = delimiter and close_map[delimiter]
                if closer then
                    found = {
                        kind = "delimiter",
                        delimiter = delimiter,
                        row = sr,
                        col = sc,
                        text = ("\\right%s"):format(closer),
                    }
                end
            end
            -- Descend only where an unmatched opener can hide: inside the node the cursor is in, or
            -- inside one the parser marked broken. Everything else is balanced and cannot contribute.
            if child:has_error() or ts.cmp(er, ec, row, col) > 0 then
                walk(child)
            end
        end
    end

    walk(root)
    return found
end

--- The leading whitespace of a row (the indent the closing line copies).
---@param buf integer
---@param row integer  0-based
---@return string
local function indent_of(buf, row)
    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    return line:match("^%s*") or ""
end

--- One indent step in this buffer's own terms ('expandtab' + 'shiftwidth').
---@param buf integer
---@return string
local function indent_unit(buf)
    local width = vim.fn.shiftwidth()
    return vim.bo[buf].expandtab and string.rep(" ", width) or "\t"
end

--- Close the innermost open construct at the cursor. Returns the construct that was closed, or nil
--- when there was nothing open (the caller then lets the key do what it normally would).
---
--- Where the text lands is defined, not guessed:
---   • a DELIMITER closes inline, at the cursor — it belongs in the formula being typed;
---   • an ENVIRONMENT closes on a LINE OF ITS OWN, indented like its `\begin`. With the cursor at the
---     end of the opener's own line (`\begin{x}` just typed) a blank, one-step-deeper body line is
---     left behind and the cursor lands on it, because that is where the next character goes;
---     `edit.close_env_body = false` turns that into the plain two-line form.
---   • on a line that is still blank, the `\end` is written IN PLACE rather than pushing an empty
---     line ahead of itself.
---@param win integer?  window (nil/0 = current)
---@return LvimTexOpenConstruct?
function M.close(win)
    win = (win == nil or win == 0) and api.nvim_get_current_win() or win
    ---@cast win integer
    local buf = api.nvim_win_get_buf(win)
    local pos = api.nvim_win_get_cursor(win)
    local row, col = pos[1] - 1, pos[2]
    local construct = M.open_construct(buf, row, col)
    if not construct then
        return nil
    end

    if construct.kind == "delimiter" then
        api.nvim_buf_set_text(buf, row, col, row, col, { construct.text })
        api.nvim_win_set_cursor(win, { row + 1, col + #construct.text })
        return construct
    end

    local line = api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local indent = indent_of(buf, construct.row)
    local before = line:sub(1, col)

    if before:match("^%s*$") and vim.trim(line) == "" then
        -- A blank line: the `\end` IS this line.
        api.nvim_buf_set_lines(buf, row, row + 1, false, { indent .. construct.text })
        api.nvim_win_set_cursor(win, { row + 1, #indent + #construct.text })
        return construct
    end

    local at_end_of_opener = construct.row == row and col >= #line
    if config.edit.close_env_body and at_end_of_opener then
        local body = indent .. indent_unit(buf)
        api.nvim_buf_set_text(buf, row, col, row, col, { "", body, indent .. construct.text })
        api.nvim_win_set_cursor(win, { row + 2, #body })
        return construct
    end

    api.nvim_buf_set_text(buf, row, col, row, col, { "", indent .. construct.text })
    api.nvim_win_set_cursor(win, { row + 2, #indent + #construct.text })
    return construct
end

--- Map the insert-mode key on a LaTeX buffer. With nothing open the key does what it always did —
--- the same fall-through `%` and `gf` use, so a configured `]]` never swallows a keystroke.
---@param buf integer
---@return nil
function M.attach(buf)
    local lhs = config.keys.edit.close_env_insert
    if not lhs or lhs == "" or not ts.is_latex(buf) or vim.b[buf].lvim_tex_insert then
        return
    end
    vim.b[buf].lvim_tex_insert = true
    vim.keymap.set("i", lhs, function()
        if M.close(0) then
            return
        end
        api.nvim_feedkeys(api.nvim_replace_termcodes(lhs, true, true, true), "ni", false)
    end, {
        buffer = buf,
        silent = true,
        desc = "lvim-tex: close the innermost open environment / delimiter",
    })
end

return M
