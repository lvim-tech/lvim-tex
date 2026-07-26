-- lvim-tex: compile the SELECTION as a document of its own.
--
-- The question this answers is "does this bit typeset, and what does it look like" — a table, a
-- tikzpicture, one equation — without waiting for the whole thesis and without hunting for the page it
-- landed on. So the selection is compiled ALONE, and the only thing that makes that possible is the
-- root document's preamble: a fragment on its own is not a document, and the packages, class options
-- and macro definitions it needs are all up there.
--
-- WHAT THE PREAMBLE IS, exactly: everything in the ROOT document from `\documentclass` up to (not
-- including) `\begin{document}`, copied VERBATIM. Not expanded, not filtered, not minimised. That
-- means an `\input{preamble}`, a `\usepackage` of a `.sty` sitting beside the root, an
-- `\addbibresource` — all of them are copied as the one line they are, and they still resolve, because
-- the run's TEXINPUTS/BIBINPUTS are pointed back at the project directory (recursively). The generated
-- document is a real document in a scratch directory, not a re-derivation of the user's project.
--
-- THE LIMITS, stated because they are inherent and not bugs to be papered over:
--   • A package the preamble does not load is NOT guessed. If the selection uses `\includegraphics`
--     and only the chapter loaded graphicx, the snippet fails exactly as it would if the preamble were
--     missing it — and the error is reported against YOUR line, in your file (see the line mapping
--     below), which is the actionable form. Inferring `\usepackage` from the selection's commands is
--     the kind of guess that silently changes what is being compiled.
--   • Anything defined in the BODY before the selection does not exist here: a `\newcommand` written
--     after `\begin{document}`, a counter the surrounding text advanced, a `\label` defined elsewhere.
--     Cross-references to labels outside the selection therefore render as `??` with a warning, never
--     an error.
--   • The selection must be BALANCED. Half of a `figure` environment is not a document, and TeX will
--     say so.
--   • The class and its options carry over unchanged — a `twocolumn` article still lays the snippet
--     out in two columns, which is usually the point.
--
-- The preamble is read from the root's LOADED BUFFER when there is one, so an unsaved `\usepackage` is
-- already in effect here (the selection itself is unsaved by definition — refusing to see one but not
-- the other would be arbitrary).
--
-- The scratch document is a genuine one-file PROJECT: it lives in its own directory, `root.out_dir`
-- and `root.pdf` derive its artefact paths exactly as they do for any other document, and the viewer
-- layer is driven through the same `on_build_start` / `on_build_done` pair the real build uses. That is
-- why the produced PDF can be shown by whichever viewer the user has configured, with no special case
-- anywhere in the viewer code.
--
-- What it deliberately does NOT do: publish diagnostics. The buffer's diagnostics belong to the
-- project's build; a snippet's errors would fight them for the same lines and outlive the run that
-- produced them. The first error is reported, mapped to the source line, and the full item list is
-- kept on `M.last` for anything that wants it.
--
---@module "lvim-tex.selection"

local config = require("lvim-tex.config")
local state = require("lvim-tex.state")
local root_mod = require("lvim-tex.root")
local log = require("lvim-tex.log")
local viewer = require("lvim-tex.viewer")

local api = vim.api
local fn = vim.fn
local fs = vim.fs

local M = {}

--- The outcome of the last selection compile — what the proofs read, and what a panel would show.
---@class LvimTexSelectionResult
---@field root   string            the project the preamble came from
---@field source string            the file the selection came from
---@field tex    string            the generated document
---@field pdf    string            where its PDF is written
---@field first  integer           1-based line of the selection's first line in `source`
---@field code   integer?          the builder's exit code (nil while running)
---@field items  LvimTexItem[]?    the generated document's log entries, lines mapped back to `source`

---@type LvimTexSelectionResult?
M.last = nil

--- Notify, gated by `config.notify`.
---@param msg string
---@param level integer?
---@return nil
local function notify(msg, level)
    if config.notify then
        vim.notify("lvim-tex: " .. msg, level or vim.log.levels.INFO)
    end
end

--- The backend module for `name`, or nil with a reason.
---@param name string
---@return table? mod, string? err
local function backend(name)
    local ok, mod = pcall(require, "lvim-tex.build." .. name)
    if not ok or type(mod) ~= "table" then
        return nil, ("builder %q is not available in this version"):format(name)
    end
    return mod, nil
end

--- The lines of `path`, from its loaded buffer when there is one, otherwise from disk.
---@param path string
---@return string[]
local function file_lines(path)
    local buf = fn.bufnr(path)
    if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
        return api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    local ok, lines = pcall(fn.readfile, path)
    return (ok and type(lines) == "table") and lines or {}
end

--- The visual selection: its text and the 1-based line it starts on.
---
--- Read from the LIVE visual positions (`v` and the cursor) when a visual mode is active, because a
--- mapping fires while the selection is still up and the `'<` / `'>` marks are only written when visual
--- mode ENDS. Outside visual mode the marks are the right source — that is the `:'<,'>` command path.
---@return string[]? lines, integer? first, string? err
local function region()
    local mode = api.nvim_get_mode().mode
    local visual = mode:sub(1, 1):match("[vV\22]") ~= nil
    local from = visual and fn.getpos("v") or fn.getpos("'<")
    local to = visual and fn.getpos(".") or fn.getpos("'>")
    if from[2] == 0 or to[2] == 0 then
        return nil, nil, "no selection — select the text first (visual mode)"
    end
    local kind = visual and mode:sub(1, 1) or fn.visualmode()
    if kind == "" then
        kind = "V"
    end
    local ok, lines = pcall(fn.getregion, from, to, { type = kind })
    if not ok or type(lines) ~= "table" or #lines == 0 then
        return nil, nil, "the selection is empty"
    end
    if #table.concat(lines, ""):gsub("%s", "") == 0 then
        return nil, nil, "the selection is blank"
    end
    return lines, math.min(from[2], to[2]), nil
end

--- The root document's preamble: `\documentclass` … the line before `\begin{document}`.
---
--- A commented-out `\begin{document}` does not end it (a `%`-led line is skipped), which is the one
--- ambiguity worth handling — everything else about the preamble is taken as written.
---@param root string
---@return string[]? preamble, string? err
function M.preamble(root)
    local lines = file_lines(root)
    local class_at, begin_at
    for i, line in ipairs(lines) do
        if not line:match("^%s*%%") then
            if not class_at and line:match("^%s*\\documentclass") then
                class_at = i
            end
            if line:find("\\begin%s*{document}") then
                begin_at = i
                break
            end
        end
    end
    if not class_at then
        return nil,
            ("%s declares no \\documentclass — a selection needs a preamble to borrow"):format(
                fn.fnamemodify(root, ":t")
            )
    end
    if not begin_at then
        return nil,
            ("%s has no \\begin{document} — the preamble has no end (is it in an \\input file?)"):format(
                fn.fnamemodify(root, ":t")
            )
    end
    return vim.list_slice(lines, class_at, begin_at - 1), nil
end

--- The scratch project for `root`: its own directory and the document written into it.
---
--- Keyed by a digest of the root's path, so two projects whose roots are both called `main.tex` never
--- share a directory, and STABLE across runs, so the aux files (and therefore latexmk's rerun
--- decisions and the viewer's page position) survive from one selection compile to the next.
---@param root string
---@return string dir, string tex
function M.workspace(root)
    local base = config.selection.dir
    if not base or base == "" then
        local cache = fn.stdpath("cache")
        ---@cast cache string
        base = cache .. "/lvim-tex/selection"
    end
    local dir = fs.normalize(base .. "/" .. fn.sha256(root):sub(1, 10))
    local name = fn.fnamemodify(root, ":t:r") .. (config.selection.suffix or "-selection") .. ".tex"
    return dir, fs.normalize(dir .. "/" .. name)
end

--- Post-run handling: parse the scratch document's log, map its lines back to the source buffer,
--- report, and tell the viewer. Named on the module so a proof can drive it with a captured result.
---@param result vim.SystemCompleted
---@param ctx { tex: string, pdf: string, body_first: integer, done: fun(res: LvimTexSelectionResult)? }
---@return nil
function M._finish(result, ctx)
    local last = M.last
    if not last or last.tex ~= ctx.tex then
        return
    end
    local project = state.project(ctx.tex)
    project.build.job = nil
    project.build.code = result.code
    project.build.status = result.code == 0 and "ok" or "failed"

    -- The generated document's own line numbers mean nothing to the user. Every entry the log
    -- attributed to the scratch file is re-pointed at the buffer the selection came from, at the line
    -- it really came from; an entry in a package or an \input-ed file keeps its own position.
    local items = log.parse(ctx.tex, root_mod.out_dir(ctx.tex))
    for _, item in ipairs(items) do
        if item.file == ctx.tex then
            item.file = last.source
            item.lnum = math.max(last.first + (item.lnum - ctx.body_first), 1)
        end
    end
    last.items = items
    last.code = result.code

    local first_error
    for _, item in ipairs(items) do
        if item.severity == vim.diagnostic.severity.ERROR then
            first_error = ("%s:%d  %s"):format(fs.basename(item.file), item.lnum, item.message)
            break
        end
    end

    if config.selection.view then
        viewer.on_build_done(
            ctx.tex,
            result.code == 0,
            first_error or ("selection failed (exit %d)"):format(result.code)
        )
    end

    if result.code == 0 then
        notify(("%s selection built → %s"):format(config.icons.ok, fn.fnamemodify(ctx.pdf, ":~")))
    else
        notify(
            ("%s selection failed: %s"):format(config.icons.fail, first_error or ("exit %d"):format(result.code)),
            vim.log.levels.WARN
        )
    end

    if ctx.done then
        ctx.done(last)
    end
end

--- Compile the current selection as a standalone document.
---@param opts { on_done: fun(res: LvimTexSelectionResult)? }?
---@return boolean started
function M.build(opts)
    opts = opts or {}
    local buf = api.nvim_get_current_buf()
    local source = fn.fnamemodify(api.nvim_buf_get_name(buf), ":p")
    local root = root_mod.of(buf)
    if not root then
        notify("this buffer has no file on disk", vim.log.levels.WARN)
        return false
    end

    local body, first, err = region()
    if not body or not first then
        notify(err or "no selection", vim.log.levels.WARN)
        return false
    end
    -- Leave visual mode: the selection has been taken, and leaving it up over an asynchronous build
    -- suggests it is still being acted on.
    if api.nvim_get_mode().mode:sub(1, 1):match("[vV\22]") then
        api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "n", false)
    end

    local preamble, why = M.preamble(root)
    if not preamble then
        notify(why or "no preamble", vim.log.levels.WARN)
        return false
    end

    local dir, tex = M.workspace(root)
    local project = state.project(tex)
    if project.build.job then
        notify("a selection is already compiling", vim.log.levels.WARN)
        return false
    end

    -- The generated document. `body_first` is where the selection's FIRST line lands in it, which is
    -- the only number the error mapping needs.
    local doc = vim.list_slice(preamble)
    doc[#doc + 1] = "\\begin{document}"
    local body_first = #doc + 1
    vim.list_extend(doc, body)
    doc[#doc + 1] = "\\end{document}"

    fn.mkdir(dir, "p")
    if fn.writefile(doc, tex) ~= 0 then
        notify(("cannot write %s"):format(tex), vim.log.levels.ERROR)
        return false
    end

    local name = root_mod.program(root) or config.builder
    local mod, no_backend = backend(name)
    if not mod then
        notify(no_backend or "no builder", vim.log.levels.ERROR)
        return false
    end
    if mod.supports and mod.supports.oneshot == false then
        notify(("builder %q is a live session and cannot compile a selection"):format(name), vim.log.levels.WARN)
        return false
    end
    local ok_bin, detail = mod.available()
    if not ok_bin then
        notify(detail or ("%s is unavailable"):format(name), vim.log.levels.ERROR)
        return false
    end

    -- The scratch document is an ordinary project, so its artefact paths come from the same two
    -- functions every other consumer uses — no second derivation to disagree with.
    local out_dir = root_mod.out_dir(tex)
    if out_dir ~= dir and not vim.uv.fs_stat(out_dir) then
        fn.mkdir(out_dir, "p")
    end
    local pdf = root_mod.pdf(tex)

    M.last = { root = root, source = source, tex = tex, pdf = pdf, first = first }
    project.build.status = "building"
    project.build.code = nil

    if config.selection.view then
        viewer.on_build_start(tex)
    end
    notify(("%s compiling %d selected line%s"):format(config.icons.building, #body, #body == 1 and "" or "s"))

    -- The scratch directory is NOT the project directory, so every relative path in the preamble (an
    -- \input, a local .sty, a graphic, the .bib) would resolve to nothing. Pointing the engine's own
    -- search paths back at the project — recursively, with the trailing separator that keeps the
    -- distribution's defaults — is what makes the copied preamble work instead of merely parse.
    local project_dir = fs.dirname(root)
    local env = vim.tbl_extend("force", mod.env(), {
        TEXINPUTS = project_dir .. "//:" .. (vim.env.TEXINPUTS or ""),
        BIBINPUTS = project_dir .. "//:" .. (vim.env.BIBINPUTS or ""),
    })

    local argv = mod.argv({
        target = tex,
        out_dir = (out_dir ~= dir) and out_dir or nil,
        engine = root_mod.engine(root),
    })

    project.build.job = vim.system(argv, {
        cwd = mod.cwd({ target = tex }),
        env = env,
        text = true,
        -- vim.system's own timeout is the watchdog here: one mechanism, and a wedged engine in a
        -- scratch directory is exactly as fatal as one in the project.
        timeout = config.selection.timeout or config.continuous.timeout,
    }, function(result)
        vim.schedule(function()
            M._finish(result, { tex = tex, pdf = pdf, body_first = body_first, done = opts.on_done })
        end)
    end)
    return true
end

return M
