-- lvim-tex: the word count (checklist row M2) — `texcount`, read rather than echoed.
--
-- Counting words in LaTeX is not a `wc -w` job: a preamble, a `\label`, a `tikzpicture` and a
-- bibliography are not prose, and a section title is prose of a different kind. `texcount` is the
-- tool that knows the difference, so this module does not count anything itself — it RUNS texcount
-- and turns its report into a structure.
--
-- Two things are deliberate:
--
--   • THE COUNT IS THE DOCUMENT'S, NOT THE BUFFER'S. `-inc` makes texcount follow `\input` and
--     `\include`, and the file it starts from is the project's compile TARGET (so `:LvimTex main`
--     moves the count with the build). Counting the buffer you happen to be in would answer a
--     question nobody asks of a multi-file thesis. `:LvimTex count file` is the per-file form when
--     that IS the question.
--
--   • THE REPORT KEEPS TEXCOUNT'S OWN ROWS. Each section's labelled lines are stored in the order
--     texcount printed them and rendered verbatim, with the numbers ALSO normalised into
--     `values.words` / `.headers` / … for anything that needs a number. A texcount that grows a row
--     therefore shows it, instead of the row being silently dropped by a parser that only knows
--     seven labels.
--
-- The report window is the canonical `lvim-ui.help` component: its row shape is exactly this — a
-- narrow, aligned left column and a description filling the width, striped and cursor-followed. A
-- second window class for "a table of label/value rows" would be the same component with a
-- different name.
--
---@module "lvim-tex.count"

local config = require("lvim-tex.config")
local root_mod = require("lvim-tex.root")
local state = require("lvim-tex.state")

local ui = require("lvim-ui")

local api = vim.api
local fn = vim.fn
local fs = vim.fs

local M = {}

--- The pointer/separator glyph the whole ecosystem uses between the parts of one row.
local ARROW = "➤"

---@class LvimTexCountSection
---@field label  string                                what was counted (a file name, or "Total")
---@field kind   "file"|"total"
---@field rows   { [1]: string, [2]: integer }[]       texcount's own labelled lines, in its order
---@field values table<string, integer>                the normalised numbers (see `FIELD`)

---@class LvimTexCountResult
---@field sections LvimTexCountSection[]  one per counted file, in texcount's order
---@field total    LvimTexCountSection?   the totals block (absent for a single-file count)
---@field target   string                 the file texcount was pointed at
---@field argv     string[]               the exact command that produced it
---@field output   string[]               the raw stdout lines (what `parse` was given)

--- texcount's row label → the normalised field name. Matched as a PREFIX on the lower-cased label,
--- because two of them carry a parenthesised tail that has changed between texcount releases
--- ("Words outside text (captions, etc.)").
---@type { [1]: string, [2]: string }[]
local FIELD = {
    { "words in text", "words" },
    { "words in headers", "headers" },
    { "words outside text", "captions" },
    { "number of headers", "header_count" },
    { "number of floats", "floats" },
    { "number of math inlines", "inlines" },
    { "number of math displayed", "displays" },
    { "files", "files" },
}

--- Section headers texcount prints, and the section KIND each opens. `Sum of files` and
--- `File(s) total` both introduce the totals (texcount prints them one after the other, with one set
--- of numbers underneath), and `-total` prints a bare `Total`.
---@type { [1]: string, [2]: string }[]
local HEADER = {
    { "^Included file:%s*(.+)$", "file" },
    { "^File:%s*(.+)$", "file" },
    { "^Sum of files:%s*(.+)$", "total" },
    { "^File%(s%) total:%s*(.+)$", "total" },
    { "^(Total)%s*$", "total" },
}

--- The normalised field name for a texcount row label, or nil when it is one we do not name.
---@param label string
---@return string?
local function field_name(label)
    local lower = label:lower()
    for _, pair in ipairs(FIELD) do
        if lower:sub(1, #pair[1]) == pair[1] then
            return pair[2]
        end
    end
    return nil
end

--- Parse texcount's report into sections. Anything that is not a section header or a `Label: number`
--- row is ignored — texcount also prints the encoding, blank separators, and (after `Subcounts:`)
--- a per-heading breakdown this report does not use.
---@param lines string[]
---@return LvimTexCountResult
function M.parse(lines)
    ---@type LvimTexCountResult
    local result = { sections = {}, total = nil, target = "", argv = {}, output = lines }
    ---@type LvimTexCountSection?
    local current = nil
    local in_subcounts = false

    for _, line in ipairs(lines) do
        local text = line:gsub("\r$", "")
        if text:match("^Subcounts:") then
            -- Everything below is the per-heading breakdown, in a different (non-labelled) shape.
            in_subcounts = true
        elseif text:match("^%S") then
            -- A non-indented line ends a Subcounts block (the breakdown rows are all indented).
            in_subcounts = false
        end

        if not in_subcounts then
            local opened = false
            for _, header in ipairs(HEADER) do
                local label = text:match(header[1])
                if label then
                    -- `Sum of files:` is immediately followed by `File(s) total:`; the second header
                    -- takes over the (still empty) section rather than opening a second one.
                    if current and current.kind == "total" and header[2] == "total" and #current.rows == 0 then
                        current.label = label
                    else
                        current = { label = label, kind = header[2], rows = {}, values = {} }
                        if header[2] == "total" then
                            result.total = current
                        else
                            result.sections[#result.sections + 1] = current
                        end
                    end
                    opened = true
                    break
                end
            end
            if not opened and current then
                local label, value = text:match("^(.-):%s*(%d+)%s*$")
                if label then
                    local number = tonumber(value) or 0
                    current.rows[#current.rows + 1] = { label, number }
                    local name = field_name(label)
                    if name then
                        current.values[name] = number
                    end
                end
            end
        end
    end

    -- A single-file count has no totals block; the one section IS the total, so every consumer can
    -- read `result.total` without a special case.
    if not result.total and #result.sections == 1 then
        result.total = result.sections[1]
    end
    return result
end

--- The exact argv a count runs — exposed so health and the proofs can assert the command without
--- spawning it.
---@param target string   the file to count
---@param opts { include?: boolean }?  `include` false drops `-inc` (count this file alone)
---@return string[]
function M.argv(target, opts)
    opts = opts or {}
    local argv = { config.count.bin }
    for _, arg in ipairs(config.count.args or {}) do
        -- `-inc` is what makes the count the DOCUMENT's; a per-file count must not carry it.
        if not (opts.include == false and arg == "-inc") then
            argv[#argv + 1] = arg
        end
    end
    argv[#argv + 1] = target
    return argv
end

--- Run texcount over `target` and hand the parsed result back.
---
--- texcount is run in the target's own directory, because the relative `\input` paths it follows are
--- written against that directory — exactly the rule the build and the log parser live by.
---@param target string
---@param opts { include?: boolean }?
---@param callback fun(result: LvimTexCountResult?, err: string?): nil
---@return nil
function M.run(target, opts, callback)
    if fn.executable(config.count.bin) ~= 1 then
        callback(nil, ("%s is not on PATH"):format(config.count.bin))
        return
    end
    local argv = M.argv(target, opts)
    vim.system(argv, {
        cwd = fs.dirname(target),
        text = true,
        timeout = config.count.timeout,
    }, function(done)
        vim.schedule(function()
            local out = done.stdout or ""
            if out == "" then
                -- texcount reports a missing file on stderr and exits 0, so an empty stdout is the
                -- only signal that nothing was counted.
                callback(
                    nil,
                    vim.trim(done.stderr or "") ~= "" and vim.trim(done.stderr) or "texcount produced no output"
                )
                return
            end
            local result = M.parse(vim.split(out, "\n", { plain = true }))
            result.target = target
            result.argv = argv
            callback(result, nil)
        end)
    end)
end

--- `path` written relative to the root's directory, which is how a report row names a file.
---@param path string
---@param root string?
---@return string
local function relative(path, root)
    if not root then
        return fn.fnamemodify(path, ":~:.")
    end
    local base = fs.dirname(root)
    if vim.startswith(path, base .. "/") then
        return path:sub(#base + 2)
    end
    return fn.fnamemodify(path, ":~:.")
end

--- The report window's rows: the totals as texcount labelled them, then (when `count.per_file`) one
--- row per counted file with its own word count.
---@param result LvimTexCountResult
---@param root string?
---@return { [1]: string, [2]: string }[]
function M.report_items(result, root)
    local items = {}
    for _, row in ipairs(result.total and result.total.rows or {}) do
        items[#items + 1] = { tostring(row[2]), row[1] }
    end
    if config.count.per_file and #result.sections > 1 then
        items[#items + 1] = { "", ("%s per file"):format(ARROW) }
        for _, section in ipairs(result.sections) do
            -- texcount names an included file relative to the directory it ran in; the label is
            -- shown as written, only tidied of the leading "./".
            local label = section.label:gsub("^%./", "")
            items[#items + 1] = { tostring(section.values.words or 0), relative(label, root) }
        end
    end
    return items
end

--- The one-line summary a notify carries — the three numbers that answer "how long is it".
---@param result LvimTexCountResult
---@return string
function M.summary(result)
    local values = (result.total and result.total.values) or {}
    local parts = {
        ("%s %d words"):format(config.icons.count, values.words or 0),
        ("%d in headings"):format(values.headers or 0),
        ("%d heading%s"):format(values.header_count or 0, (values.header_count or 0) == 1 and "" or "s"),
    }
    if values.files and values.files > 1 then
        parts[#parts + 1] = ("%d files"):format(values.files)
    end
    return table.concat(parts, ("  %s  "):format(ARROW))
end

--- Show a parsed count: the summary as a notify line, the full table in the canonical help window.
---@param result LvimTexCountResult
---@param root string?
---@return nil
function M.show(result, root)
    vim.notify("lvim-tex: " .. M.summary(result), vim.log.levels.INFO)
    ui.help({
        title = ("%s Word count  %s  %s"):format(config.icons.count, ARROW, relative(result.target, root)),
        items = M.report_items(result, root),
    })
end

--- The lines of the current visual selection (or the last one, when visual mode has already been
--- left — which is what a `:'<,'>` command line has done by the time it runs).
---@param buf integer
---@return string[]? lines
---@return integer? first  1-based first line
---@return integer? last   1-based last line
local function selection_lines(buf)
    local mode = api.nvim_get_mode().mode
    local first, last
    if mode:sub(1, 1) == "v" or mode:sub(1, 1) == "V" or mode:sub(1, 1) == "\22" then
        first = api.nvim_win_get_cursor(0)[1]
        last = fn.line("v")
    else
        first, last = fn.line("'<"), fn.line("'>")
    end
    if not first or not last or first < 1 or last < 1 then
        return nil, nil, nil
    end
    if first > last then
        first, last = last, first
    end
    return api.nvim_buf_get_lines(buf, first - 1, last, false), first, last
end

--- Count the visual selection. The lines are written to a scratch `.tex` file because texcount reads
--- a FILE (it has no stdin mode), and the scratch file is removed as soon as the count comes back.
---@param buf integer
---@return nil
function M.selection(buf)
    local lines, first, last = selection_lines(buf)
    if not lines or #lines == 0 then
        vim.notify("lvim-tex: nothing selected", vim.log.levels.WARN)
        return
    end
    local dir = fn.stdpath("cache") .. "/lvim-tex"
    fn.mkdir(dir, "p")
    local path = ("%s/count-selection.tex"):format(dir)
    local ok = pcall(fn.writefile, lines, path)
    if not ok then
        vim.notify(("lvim-tex: could not write %s"):format(path), vim.log.levels.ERROR)
        return
    end
    local root = root_mod.of(buf)
    M.run(path, { include = false }, function(result, err)
        fn.delete(path)
        if not result then
            vim.notify(("lvim-tex: %s"):format(err or "the count failed"), vim.log.levels.WARN)
            return
        end
        result.target = ("selection (lines %d-%d)"):format(first or 0, last or 0)
        M.show(result, root)
    end)
end

--- `:LvimTex count [file|selection]` / `,lw` — count the project, this file alone, or the selection.
---@param buf integer?
---@param arg string?  "file" counts only the current buffer's file; "selection" the visual range
---@return nil
function M.count(buf, arg)
    buf = buf or api.nvim_get_current_buf()
    if arg == "selection" then
        M.selection(buf)
        return
    end
    local root = root_mod.of(buf)
    if not root then
        vim.notify("lvim-tex: this buffer has no file on disk", vim.log.levels.WARN)
        return
    end
    local target = (arg == "file") and fn.fnamemodify(api.nvim_buf_get_name(buf), ":p")
        or state.project(root).target
        or root
    M.run(target, { include = arg ~= "file" }, function(result, err)
        if not result then
            vim.notify(("lvim-tex: %s"):format(err or "the count failed"), vim.log.levels.WARN)
            return
        end
        M.show(result, root)
    end)
end

return M
