-- lvim-tex: the TeX log → diagnostics parser.
--
-- A TeX log is not a diagnostic stream, it is a transcript: messages are wrapped at a fixed column,
-- the file a message belongs to is implied by nesting parentheses rather than stated, and every
-- package invents its own wording. Parsing it therefore happens in three passes, each with one job:
--
--   PASS 1 (records)  — un-wrap. Physical log lines are joined back into logical records, and the
--                       current FILE is tracked through the log's paren nesting: `(./chapters/ch1.tex`
--                       pushes, the matching `)` pops. Only paren-tokens that look like a path push,
--                       so the countless `)` of ordinary maths never corrupt the stack.
--   PASS 2 (classify) — recognise the four SHAPES that carry position: `file:line: message` errors
--                       (that is what `-file-line-error` buys us), warning blocks with their
--                       `on input line N` tail, over/underfull box reports, and the bare `! message`
--                       error form for engines that ignore the flag.
--   PASS 3 (rules)    — a RULE TABLE refines a classified record: a package's own phrasing gets a
--                       precise severity, message and position. Rules are data, so coverage grows by
--                       adding a row (see `diagnostics.rules` and doc/lvim-tex.txt), never by editing
--                       this file. A record that matches NO rule is still emitted, attributed to the
--                       file it was found in — nothing is ever dropped silently, which is what makes
--                       the shipped rule set safe to grow one package at a time.
--
-- The result is a plain list of items (file/lnum/severity/message/rule); publishing them as
-- vim.diagnostic or a quickfix list is the caller's business (see lvim-tex.build).
--
---@module "lvim-tex.log"

local config = require("lvim-tex.config")
local rules = require("lvim-tex.log.rules")

local fn = vim.fn
local fs = vim.fs
local uv = vim.uv

local M = {}

local S = vim.diagnostic.severity

--- One parsed log record, before the rule pass.
---@class LvimTexRecord
---@field text   string    the un-wrapped message text
---@field file   string?   the file the log was inside when the record appeared
---@field lnum   integer?  1-based line, when the record carried one
---@field kind   "error"|"warning"|"box"|"info"
---@field raw    string    the first physical line, for debugging
---@field target string?   the file that was COMPILED — a rule needs it to re-attribute an entry the
---                        log raised inside a package to the line that asked for the package

--- One publishable item.
---@class LvimTexItem
---@field file     string
---@field lnum     integer
---@field col      integer
---@field severity integer   a vim.diagnostic.severity value
---@field message  string
---@field rule     string    id of the rule that produced it ("generic" when none matched)

-- TeX wraps its log at `max_print_line` columns, so a physical line of exactly that width CONTINUES
-- on the next one. The width is not recorded anywhere in the log, and assuming the 79-column default
-- unconditionally CORRUPTS every log written with a wider one — our own builds set `max_print_line`
-- to 10000, where a 120-character message would swallow the line after it.
--
-- What the format does guarantee is the other direction: TeX never writes a line LONGER than
-- `max_print_line`. So a log containing no line over 79 was written with the default and its
-- 79-character lines are continuations; a log containing a longer line was not, and where it would
-- have wrapped — if at all — is unknowable, so nothing is joined.
--
-- Inferring the width from "the length many lines share" was tried and is wrong: with our build
-- environment the shared maximum is `half_error_line` (238), which is the ERROR CONTEXT display, not
-- a wrapped message.
local WRAP = 79

--- The width at which THIS log wraps, or math.huge when it does not wrap at all.
---@param lines string[]
---@return number
local function wrap_width(lines)
    for _, line in ipairs(lines) do
        if #line > WRAP then
            return math.huge
        end
    end
    return WRAP
end

--- Does this token look like a path TeX just opened, rather than any other parenthesis?
--- `(./main.tex`, `(/usr/share/texmf/tex/latex/base/article.cls`, `("with spaces.tex"`.
---@param token string
---@return boolean
local function path_like(token)
    if token == "" then
        return false
    end
    return token:match("^%./") ~= nil
        or token:match("^%.%./") ~= nil
        or token:match("^/") ~= nil
        or token:match("^%a[%w_%-%.]*%.%a+$") ~= nil
        or token:match("^[%w_%-%./]+%.%a%a%a?%a?$") ~= nil
end

--- PASS 1 — join wrapped lines into logical records and track the file stack.
---@param lines string[]     raw log lines
---@param dir string         directory the engine ran in (relative paths resolve against it)
---@return { text: string, file: string?, raw: string }[]
local function records(lines, dir)
    local out = {}
    -- Every OPEN parenthesis, innermost last — `false` for one that opened no file. A file stack that
    -- only remembers the file-opening parens has no way to tell which `)` closes what, so a message's
    -- own `(natbib)` or `(minted executable is …)` pops a REAL file off it and every diagnostic after
    -- that is attributed to the wrong document.
    ---@type (string|false)[]
    local stack = {}
    local pending = nil ---@type { text: string, file: string?, raw: string }?
    local wrap = wrap_width(lines)

    --- The file the log is currently inside: the innermost paren that opened one.
    ---@return string?
    local function current()
        for i = #stack, 1, -1 do
            local entry = stack[i]
            if entry then
                return entry
            end
        end
        return nil
    end

    --- Absolute form of a path token from the log.
    ---@param token string
    ---@return string
    local function absolute(token)
        token = token:gsub('^"(.*)"$', "%1")
        if token:sub(1, 1) == "/" then
            return token
        end
        return fn.fnamemodify(fs.normalize(dir .. "/" .. token), ":p")
    end

    for _, line in ipairs(lines) do
        -- TeX's own message machinery indents the CONTINUATION of a multi-line message with the
        -- package's name in parentheses:
        --
        --     /…/fontspec.sty:101: Fatal Package fontspec Error: The fontspec package requires
        --     (fontspec)                      either XeTeX or LuaTeX.
        --
        -- Those are not records of their own — treated as such, every long package message is
        -- reported truncated at its first line, and each continuation becomes a diagnostic saying
        -- nothing. `(/path/file.tex` (a file the engine opened) cannot be confused with this: the
        -- marker's `)` closes immediately after a bare name.
        local marker, rest = line:match("^%(([%w@%-]+)%)%s*(.*)$")
        if marker and not pending and #out > 0 then
            if rest ~= "" then
                out[#out].text = out[#out].text .. " " .. rest
            end
            goto continue
        end

        -- Continuation: the previous physical line filled the wrap width exactly, so this one is the
        -- rest of the same message. Records are flushed when a line is SHORT (or a new shape starts).
        if pending then
            pending.text = pending.text .. line
            if #line < wrap then
                out[#out + 1] = pending
                pending = nil
            end
        else
            local rec = { text = line, file = current(), raw = line }
            if #line >= wrap then
                pending = rec
            else
                out[#out + 1] = rec
            end
        end

        -- The file stack advances per PHYSICAL line, because a `(path` token may be the last thing on
        -- a wrapped line. Brackets are consumed left to right so `(a.tex (b.tex))` nests correctly.
        local i = 1
        while i <= #line do
            local ch = line:sub(i, i)
            if ch == "(" then
                local token = line:match("^([^%s%(%)]+)", i + 1) or ""
                if path_like(token) then
                    stack[#stack + 1] = absolute(token)
                    i = i + #token
                else
                    stack[#stack + 1] = false
                end
            elseif ch == ")" then
                if #stack > 0 then
                    stack[#stack] = nil
                end
            end
            i = i + 1
        end
        ::continue::
    end
    if pending then
        out[#out + 1] = pending
    end
    return out
end

--- PASS 2 — give a record a kind and, where the shape carries one, a file and line.
---@param rec { text: string, file: string?, raw: string }
---@param dir string
---@return LvimTexRecord?
local function classify(rec, dir)
    local text = rec.text

    --- Absolute form of a file token found INSIDE a message.
    ---@param token string
    ---@return string
    local function abs(token)
        if token:sub(1, 1) == "/" then
            return token
        end
        return fn.fnamemodify(fs.normalize(dir .. "/" .. token), ":p")
    end

    -- `-file-line-error` shape: `./chapters/ch1.tex:42: Undefined control sequence.`
    local file, lnum, msg = text:match("^(..-):(%d+):%s*(.+)$")
    if file and lnum and msg and not file:match("^%s*!") then
        return { text = msg, file = abs(file), lnum = tonumber(lnum), kind = "error", raw = rec.raw }
    end

    -- Bare error shape, for an engine or a rerun without the flag: `! Undefined control sequence.`
    local bare = text:match("^!%s*(.+)$")
    if bare then
        return { text = bare, file = rec.file, lnum = nil, kind = "error", raw = rec.raw }
    end

    -- Over/underfull boxes carry their own position: `Overfull \hbox (12.3pt too wide) in paragraph
    -- at lines 41--43`.
    local box = text:match("^(Overfull.*)$") or text:match("^(Underfull.*)$")
    if box then
        local at = box:match("at lines (%d+)%-%-") or box:match("at line (%d+)")
        return { text = box, file = rec.file, lnum = at and tonumber(at) or nil, kind = "box", raw = rec.raw }
    end

    -- Warnings: `LaTeX Warning: …`, `Package hyperref Warning: …`, `Class article Warning: …`,
    -- `LaTeX Font Warning: …`, and biber/biblatex's own `WARN - …`.
    local warn = text:match("^[%w%s]-Warning:%s*(.+)$")
        or text:match("^Package%s+[%w@%-]+%s+Warning:%s*(.+)$")
        or text:match("^Class%s+[%w@%-]+%s+Warning:%s*(.+)$")
        or text:match("^WARN%s+%-%s*(.+)$")
    if warn then
        local at = text:match("on input line (%d+)")
        return {
            text = vim.trim(warn),
            file = rec.file,
            lnum = at and tonumber(at) or nil,
            kind = "warning",
            raw = rec.raw,
        }
    end

    -- biber/bibtex errors are reported outside the TeX log's own conventions.
    local biber = text:match("^ERROR%s+%-%s*(.+)$") or text:match("^Database error:%s*(.+)$")
    if biber then
        return { text = vim.trim(biber), file = rec.file, lnum = nil, kind = "error", raw = rec.raw }
    end

    return nil
end

-- Kind → default severity, before any rule refines it.
---@type table<string, integer>
local KIND_SEVERITY = {
    error = S.ERROR,
    warning = S.WARN,
    box = S.HINT,
    info = S.INFO,
}

--- Is `message` filtered out by `diagnostics.ignore`?
---@param message string
---@return boolean
local function ignored(message)
    for _, pattern in ipairs(config.diagnostics.ignore) do
        local ok, hit = pcall(string.find, message, pattern)
        if ok and hit then
            return true
        end
    end
    return false
end

-- Entries that are a CONSEQUENCE of an earlier failure rather than a failure of their own: TeX prints
-- them after the error that actually stopped the run. They are worth keeping only when nothing else
-- was reported — a lone "Emergency stop." is still better than silence, three of them stacked on top
-- of the real error are noise.
---@type table<string, boolean>
local CONSEQUENCE = {
    ["latex.emergency-stop"] = true,
    ["engine.no-output"] = true,
}

--- Drop the consequence entries when a real error is present, and collapse entries that are byte-for
--- byte the same position and message (a package that raises its error once per pass).
---@param items LvimTexItem[]
---@return LvimTexItem[]
local function prune(items)
    local real_error = false
    for _, item in ipairs(items) do
        if item.severity == S.ERROR and not CONSEQUENCE[item.rule] then
            real_error = true
            break
        end
    end
    local out, seen = {}, {}
    for _, item in ipairs(items) do
        local key = ("%s:%d:%d:%d:%s"):format(item.file, item.lnum, item.col, item.severity, item.message)
        if not (real_error and CONSEQUENCE[item.rule]) and not seen[key] then
            seen[key] = true
            out[#out + 1] = item
        end
    end
    return out
end

--- PASS 3 — the rule table. Returns the refined item, or nil when a rule DROPS the record.
---@param rec LvimTexRecord
---@param root string  fallback file for a record the log could not attribute
---@return LvimTexItem?
local function apply_rules(rec, root)
    ---@type LvimTexItem
    local item = {
        file = rec.file or root,
        lnum = rec.lnum or 1,
        col = 1,
        severity = KIND_SEVERITY[rec.kind] or S.INFO,
        message = rec.text,
        rule = "generic",
    }

    -- Shipped rules first, then the user's — so a user rule can override a shipped verdict for the
    -- same record simply by matching it too.
    local table_of_rules = vim.list_extend(vim.list_extend({}, rules.all()), config.diagnostics.rules)
    for _, rule in ipairs(table_of_rules) do
        local hit ---@type boolean|table|nil
        if type(rule.match) == "function" then
            hit = rule.match(rec)
        else
            hit = rec.text:find(rule.match) ~= nil
        end
        if hit then
            item.rule = rule.id or "user"
            if rule.severity then
                item.severity = rule.severity
            end
            if rule.extract then
                local patch = rule.extract(rec)
                if patch == false then
                    return nil -- the rule says this record is noise
                end
                if type(patch) == "table" then
                    item.file = patch.file or item.file
                    item.lnum = patch.lnum or item.lnum
                    item.col = patch.col or item.col
                    item.message = patch.message or item.message
                end
            end
            break
        end
    end

    return item
end

--- Parse a log's LINES into publishable items.
---
--- `base_dir` is the directory the ENGINE RAN IN, which is what every relative path in a TeX log is
--- recorded against — never the build directory. With `-outdir=build` the log itself lives in
--- `build/` while its paths still read `./chapters/ch1.tex`, relative to the project; resolving them
--- against the build dir yields `build/chapters/ch1.tex`, a file that does not exist and a buffer
--- that never matches.
---@param lines string[]
---@param target string    the compiled file, used as the fallback attribution
---@param base_dir string? the engine's working directory (default: the target's own directory)
---@return LvimTexItem[]
function M.parse_lines(lines, target, base_dir)
    local dir = base_dir or fs.dirname(target)
    local items = {}
    for _, rec in ipairs(records(lines, dir)) do
        local classified = classify(rec, dir)
        if classified then
            classified.target = target
            local keep = classified.kind ~= "box" or config.diagnostics.boxes
            if keep and classified.kind == "warning" and not config.diagnostics.warnings then
                keep = false
            end
            if keep and not ignored(classified.text) then
                local item = apply_rules(classified, target)
                if item then
                    items[#items + 1] = item
                end
            end
        end
    end
    return prune(items)
end

--- Parse the log FILE of the last build of `target`.
---@param target string    the compiled file (the log is named after it)
---@param log_dir string?  where the build wrote its artefacts (nil = beside the target)
---@return LvimTexItem[] items, string? log_path
function M.parse(target, log_dir)
    local jobname = fn.fnamemodify(fs.basename(target), ":r")
    local base_dir = fs.dirname(target)
    local path = (log_dir or base_dir) .. "/" .. jobname .. ".log"
    if not uv.fs_stat(path) then
        return {}, nil
    end
    local ok, lines = pcall(fn.readfile, path)
    if not ok or type(lines) ~= "table" then
        return {}, path
    end
    return M.parse_lines(lines, target, base_dir), path
end

return M
