-- lvim-tex: LaTeX support for the lvim-tech ecosystem — the public entry point.
--
-- lvim-tex owns what is TeX-SPECIFIC and nothing else, because the generic layers already exist:
-- lvim-lang wires texlab and latexindent, lvim-ts owns the grammars, lvim-snippets the snippet
-- engine, lvim-preview the viewer. What no generic layer can express is the document itself — which
-- file IS the document, how it is built, what its log means, and where a position in the PDF maps
-- back to in the source. That is this plugin.
--
-- Keys are BUFFER-LOCAL and hang off `<localleader>` (`,` by default), so `,ll` exists only inside a
-- TeX buffer and the global `<leader>` groups are untouched. Every map carries a `desc`, which is
-- what lvim-keys-helper renders — nothing has to be registered centrally.
--
---@module "lvim-tex"

local config = require("lvim-tex.config")
local state = require("lvim-tex.state")
local root_mod = require("lvim-tex.root")
local build = require("lvim-tex.build")
local selection = require("lvim-tex.selection")
local rules = require("lvim-tex.log.rules")
local viewer = require("lvim-tex.viewer")
local textobjects = require("lvim-tex.textobjects")
local motion = require("lvim-tex.motion")
local match = require("lvim-tex.match")
local edit = require("lvim-tex.edit")
local syntax = require("lvim-tex.syntax")
local conceal = require("lvim-tex.conceal")
local completion = require("lvim-tex.completion")
local insert = require("lvim-tex.insert")
local imaps = require("lvim-tex.imaps")
local tex_snippets = require("lvim-tex.snippets")

local ok_utils, utils = pcall(require, "lvim-utils.utils")

local api = vim.api
local fn = vim.fn

local M = {}

---@type integer?  the plugin's augroup, created once by setup()
local augroup = nil

---@type uv.uv_timer_t?  debounce for the cursor-follow forward search
local follow_timer = nil

--- Release the follow debounce (a reload or a second setup must not leak the timer).
---@return nil
local function release_follow()
    if follow_timer then
        follow_timer:stop()
        if not follow_timer:is_closing() then
            follow_timer:close()
        end
        follow_timer = nil
    end
end

--- Move the viewer to where the reader is, after they have been still.
---
--- TWO KINDS, because "where the reader is" has two answers and a scroll gives the other one. A
--- CURSOR move is answered by the cursor; a SCROLL is answered by the window CENTRE, because the
--- cursor did not move — Neovim keeps it in the window, so after CTRL-E it is simply wherever the
--- view left it. Sending the cursor for a scroll was the whole of the bug: the event fired (when it
--- fired at all), resolved the same source line as last time, and the viewer stayed put while the
--- reader scrolled a page away.
---
--- The position is read when the TIMER FIRES, not when the event arrives: a burst of scrolls must
--- land on where the view came to rest, and the last trigger of either kind wins the shared timer.
---
--- Deliberately narrow: it does nothing outside a TeX buffer that belongs to a project, and what it
--- may do to a viewer at all — never open one, never take the focus from the buffer — is decided by
--- `viewer.follow`. A forward search costs a `synctex` process, so it is debounced rather than sent
--- per event.
---@param kind "cursor"|"scroll"
---@return nil
local function schedule_follow(kind)
    if not config.synctex.follow_cursor then
        return
    end
    if kind == "scroll" and config.synctex.follow_scroll == false then
        return
    end
    -- No filetype check: the file NAME is the gate (the `CursorMoved` autocmd expresses it as a
    -- pattern; the `WinScrolled` one cannot — see setup() — so both end up here). A `&filetype`
    -- guard would make this unprovable outside a UI, since detection is off under
    -- `nvim --headless -u NONE`.
    local buf = api.nvim_get_current_buf()
    local name = api.nvim_buf_get_name(buf)
    if not (name:match("%.tex$") or name:match("%.ltx$")) then
        return
    end
    local root = root_mod.of(buf)
    if not root then
        return
    end
    local file = fn.fnamemodify(name, ":p")
    local win = api.nvim_get_current_win()
    release_follow()
    local timer = vim.uv.new_timer()
    if not timer then
        return
    end
    follow_timer = timer
    timer:start(
        math.max(0, config.synctex.follow_debounce or 400),
        0,
        vim.schedule_wrap(function()
            release_follow()
            if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= buf then
                return
            end
            local lnum, col
            if kind == "scroll" then
                -- The line at the middle ROW of the window, which is what `M` means — not the
                -- numeric average of the first and last buffer line numbers. Under 'wrap' the two
                -- differ: measured on a wrapped chapter, the average was 1–2 buffer lines off, and in
                -- a book where one buffer line is a whole paragraph that aims the viewer up to a
                -- paragraph away from what is actually mid-screen. The view is saved and restored
                -- around it because `M` moves the cursor, and this must not.
                api.nvim_win_call(win, function()
                    local view = fn.winsaveview()
                    vim.cmd("keepjumps normal! M")
                    lnum = fn.line(".")
                    fn.winrestview(view)
                end)
                col = 1
            else
                local pos = api.nvim_win_get_cursor(win)
                lnum, col = pos[1], pos[2] + 1
            end
            -- `viewer.follow` owns every condition that makes an automatic sync safe — a viewer must
            -- already be open, and it must be one that can be moved without taking the focus. Those
            -- are facts about viewers, so the gate lives with them and not here.
            viewer.follow(root, file, lnum, col)
        end)
    )
end

--- Notify, gated by `config.notify`.
---@param msg string
---@param level integer?
---@return nil
local function notify(msg, level)
    if config.notify then
        vim.notify("lvim-tex: " .. msg, level or vim.log.levels.INFO)
    end
end

--- Toggle the compile target between the root document and the current file.
---@return nil
function M.toggle_main()
    local target = root_mod.toggle_target(0)
    if not target then
        notify("this buffer has no file on disk", vim.log.levels.WARN)
        return
    end
    local root = root_mod.of(0)
    -- The build now writes a different PDF, so an open viewer has to follow it — otherwise it keeps
    -- showing the other document and looks like the toggle did nothing.
    if root then
        viewer.retarget(root)
    end
    local kind = (target == root) and "root document" or "this subfile"
    -- A target with no PDF has nothing to show, and the user toggled precisely in order to see it — so
    -- BUILD it (`root.build_on_toggle`). Reporting the state and waiting would demand a save of a file
    -- nobody changed, purely to make the tool act. A target that already has a PDF is shown as it is;
    -- the next save rebuilds it like any other.
    local missing = root ~= nil and fn.filereadable(root_mod.pdf(root, target)) ~= 1
    local building = missing and config.root.build_on_toggle == true
    notify(
        ("%s compile target: %s (%s)%s"):format(
            config.icons.section,
            fn.fnamemodify(target, ":t"),
            kind,
            building and "  (building it now)" or (missing and "  (not built yet)" or "")
        )
    )
    if building then
        -- The build opens the viewer itself when `viewer.open_on_start` allows it.
        build.build(0)
    elseif root then
        -- Nothing to build, so the only thing left to do about a toggle is to SHOW the file it points
        -- at. `show` is a no-op when a viewer is already up or when the user has not asked for one to
        -- be opened unprompted.
        viewer.show(root)
    end
end

--- Open the quickfix list holding the last build's entries.
---@return nil
function M.errors()
    if fn.getqflist({ size = 0 }).size == 0 then
        notify("no build entries")
        return
    end
    vim.cmd("botright copen")
end

--- Open the viewer AND put it where the cursor is — the two halves of "show me this".
---
--- Nothing is built first: `,lv` after an edit would otherwise mean "build, wait, then maybe show
--- something", which is `,ll` with a delay. The viewer shows whatever the last build produced, and the
--- default one says so when that is nothing yet. The forward search is skipped silently when there is
--- no PDF or no SyncTeX data — opening the viewer is still the useful half.
---@return nil
function M.view()
    local root = root_mod.of(0)
    if not root then
        notify("this buffer has no file on disk", vim.log.levels.WARN)
        return
    end
    local buf = api.nvim_get_current_buf()
    local file = fn.fnamemodify(api.nvim_buf_get_name(buf), ":p")
    local pos = api.nvim_win_get_cursor(0)
    if not viewer.is_alive(root) then
        local ok, err = viewer.open(root)
        if not ok then
            notify(err or "no viewer available", vim.log.levels.WARN)
            return
        end
    end
    local pdf = root_mod.pdf(root, state.project(root).target)
    if fn.filereadable(pdf) ~= 1 then
        notify(("%s no PDF yet — build first (%s)"):format(config.icons.viewer, fn.fnamemodify(pdf, ":~")))
        return
    end
    viewer.forward(root, file, pos[1], pos[2] + 1, function(ok, err)
        if not ok and err then
            notify(err, vim.log.levels.WARN)
        end
    end)
end

--- REVERSE SEARCH: move the cursor to whatever the viewer is currently showing.
---
--- The manual counterpart of the page poll, and the honest reverse direction for a viewer that
--- cannot report anything finer than a page — which is every external one. Ctrl-click in the viewer
--- answers "the source of THIS"; this answers "the source of what I am looking at", without leaving
--- the keyboard.
---
--- It works whether or not the automatic poll is on: that switch decides whether the editor follows
--- BY ITSELF, and asking is always allowed.
---@return nil
function M.reverse()
    local root = root_mod.of(0)
    if not root then
        notify("this buffer has no file on disk", vim.log.levels.WARN)
        return
    end
    viewer.position(root, function(page, mod)
        if not page then
            local why = (not mod and "no viewer available")
                or (mod.supports.position ~= true and ("%s cannot report which page it is showing"):format(mod.name))
                or ("%s is not showing this project"):format(mod.name)
            notify(why, vim.log.levels.WARN)
            return
        end
        local pdf = root_mod.pdf(root, state.project(root).target)
        require("lvim-tex.synctex").reverse_page(pdf, page, function(ok, err)
            if not ok then
                notify(err or "reverse search found nothing", vim.log.levels.WARN)
            end
        end)
    end)
end

--- Close this project's viewer.
---@return nil
function M.view_close()
    local root = root_mod.of(0)
    if not root then
        return
    end
    viewer.close(root)
end

--- Drop the cached project data (root, include graph, watch set) and re-read it on next use.
--- Running builds are left alone — this is "re-read the project", not a kill switch.
---@return nil
function M.reload()
    state.reset()
    -- The sync link is state too, and outliving a reload is exactly wrong: its last exchanged line
    -- would keep suppressing a valid follow until something else happened to change it.
    require("lvim-tex.synctex").reset()
    -- The conceal maps are built from config + the shipped data; a reload re-reads the project AND
    -- whatever the user changed in the config since setup.
    conceal.refresh()
    imaps.refresh()
    notify("project data reloaded")
end

--- The viewer line of `:LvimTex info`: which viewer this project is showing in, or — when none is —
--- which one WOULD be used, so the report answers "why did nothing open" as well as "what is open".
---@param root string
---@return string
local function viewer_line(root)
    if not config.viewer.enabled then
        return "disabled (viewer.enabled = false)"
    end
    if viewer.is_alive(root) then
        return ("%s (open)"):format(state.project(root).viewer)
    end
    local mod, err = viewer.resolve()
    if not mod then
        return err or "none available"
    end
    return ("%s (not open)"):format(mod.name)
end

--- What lvim-tex currently believes about the project the cursor is in. The P1 form is a text
--- report; the build panel that replaces it arrives with the continuous lifecycle.
---@return string[]  the reported lines (returned as well as shown, so the proofs can assert them)
function M.info()
    local root = root_mod.of(0)
    if not root then
        notify("this buffer has no file on disk", vim.log.levels.WARN)
        return {}
    end
    local project = state.project(root)
    local engine = root_mod.engine_for(root, project.target)
    local graph = root_mod.graph(root)
    local watch = root_mod.watch(root, project.target, root_mod.out_dir(root, project.target))
    local errors, warnings = 0, 0
    for _, item in ipairs(project.diags or {}) do
        if item.severity == vim.diagnostic.severity.ERROR then
            errors = errors + 1
        elseif item.severity == vim.diagnostic.severity.WARN then
            warnings = warnings + 1
        end
    end

    local lines = {
        ("root      %s"):format(root),
        ("target    %s"):format(project.target),
        ("builder   %s%s"):format(
            root_mod.program_for(root, project.target) or config.builder,
            engine and (" (" .. engine .. ")") or ""
        ),
        ("out dir   %s"):format(root_mod.out_dir(root, project.target)),
        ("pdf       %s%s"):format(
            fn.fnamemodify(root_mod.pdf(root, project.target), ":~"),
            fn.filereadable(root_mod.pdf(root, project.target)) == 1 and "" or "  (not built)"
        ),
        ("viewer    %s"):format(viewer_line(root)),
        ("includes  %d file%s"):format(#graph, #graph == 1 and "" or "s"),
        ("watching  %d file%s"):format(#watch, #watch == 1 and "" or "s"),
        ("build     %s%s"):format(
            project.build.status,
            project.build.code and (" (exit %d)"):format(project.build.code) or ""
        ),
        ("entries   %d error%s, %d warning%s"):format(
            errors,
            errors == 1 and "" or "s",
            warnings,
            warnings == 1 and "" or "s"
        ),
    }
    -- Which rule produced each entry is the difference between a debuggable verdict and a mysterious
    -- one, so the report names them.
    local matched = {}
    for _, item in ipairs(project.diags or {}) do
        matched[item.rule] = (matched[item.rule] or 0) + 1
    end
    local ids = vim.tbl_keys(matched)
    table.sort(ids)
    for _, id in ipairs(ids) do
        lines[#lines + 1] = ("  rule    %s ×%d"):format(id, matched[id])
    end

    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
    return lines
end

--- A ready-made lvim-hud chrome SEGMENT for the build state — drop it into a statusline / winbar
--- segment list (the lvim-preview / lvim-breadcrumbs `hud_segment` pattern).
---
--- It renders ONLY in a buffer that belongs to a project which has BUILT (or is building), so the chip
--- appears when there is something to say and disappears otherwise. The colour carries the state:
--- building yellow, ok green, failed red — the glyph alone is easy to miss mid-edit.
---@param opts { name?: string, inactive?: boolean }?
---@return table  LvimChromeSegment
function M.hud_segment(opts)
    opts = opts or {}
    return {
        name = opts.name or "tex",
        when = function(ctx)
            if not (opts.inactive or ctx.active) then
                return false
            end
            if not vim.tbl_contains(config.filetypes, vim.bo[ctx.buf].filetype) then
                return false
            end
            local root = root_mod.of(ctx.buf)
            return root ~= nil and state.project(root).build.status ~= "idle"
        end,
        content = function(ctx)
            local root = root_mod.of(ctx.buf)
            local project = root and state.project(root) or nil
            if not project then
                return ""
            end
            local b = project.build
            local COLOUR = { building = "Yellow", ok = "Green", failed = "Red" }
            local text = (" %s "):format(build.status_text(ctx.buf))
            -- A failed build says HOW MANY errors: a red dot alone makes the user open the panel to
            -- learn whether it is one typo or a broken preamble.
            if b.status == "failed" then
                local errors = 0
                for _, item in ipairs(project.diags or {}) do
                    if item.severity == vim.diagnostic.severity.ERROR then
                        errors = errors + 1
                    end
                end
                text = (" %s %d "):format(build.status_text(ctx.buf), errors)
            end
            local ok, parts = pcall(require, "lvim-hud.chrome.parts")
            return ok and parts.seg(COLOUR[b.status] or "Green", text) or text
        end,
    }
end

--- Every rule id the shipped set provides, grouped by package (health and the vimdoc use this).
---@return table<string, string[]>
function M.rules()
    return rules.by_package()
end

-- The subcommands implemented in this version, each with the handler and the completion text.
---@type table<string, fun(arg: string?): any>
local COMMANDS = {
    build = function()
        build.build(0)
    end,
    selection = function()
        -- From the command line the marks are the selection: `:'<,'>LvimTex selection`, or the last
        -- one if visual mode has already been left.
        selection.build()
    end,
    continuous = function()
        build.toggle_continuous(0)
    end,
    stop = function()
        build.stop(0)
    end,
    stop_all = function()
        build.stop_all()
    end,
    clean = function(arg)
        build.clean(0, arg == "full")
    end,
    reverse = function()
        M.reverse()
    end,
    main = function()
        M.toggle_main()
    end,
    errors = function()
        M.errors()
    end,
    info = function()
        M.info()
    end,
    output = function()
        require("lvim-tex.panel").open(0)
    end,
    view = function(arg)
        if arg == "close" then
            M.view_close()
        else
            M.view()
        end
    end,
    reload = function()
        M.reload()
    end,
    toc = function(arg)
        local layouts = { split = true, float = true, area = true, bottom = true }
        require("lvim-tex.outline").toggle({ layout = layouts[arg or ""] and arg or nil })
    end,
    files = function()
        require("lvim-tex.pickers").files(0)
    end,
    labels = function()
        require("lvim-tex.pickers").labels(0)
    end,
    cites = function()
        require("lvim-tex.pickers").cites(0)
    end,
    cite = function(arg)
        require("lvim-tex.cite").open(arg)
    end,
    count = function(arg)
        require("lvim-tex.count").count(0, arg)
    end,
    doc = function(arg)
        require("lvim-tex.doc").doc(arg)
    end,
    conceal = function(arg)
        conceal.toggle(0, arg)
    end,
    imaps = function(arg)
        if arg == "toggle" or arg == "on" or arg == "off" then
            local on = imaps.toggle(arg ~= "off" and (arg == "on" or nil))
            notify(("maths abbreviations %s"):format(on and "on" or "off"))
        else
            imaps.list()
        end
    end,
    matchparen = function()
        local on = match.toggle_highlight()
        notify(("matching-pair highlight %s"):format(on and "on" or "off"))
    end,
}

--- Install the buffer-local keymaps for `buf`.
---@param buf integer
---@return nil
local function attach_keys(buf)
    local keys = config.keys
    local prefix = keys.prefix or ""

    --- Map `prefix .. suffix` when the suffix is set.
    ---@param suffix string|false|nil
    ---@param rhs fun(): any
    ---@param desc string
    ---@return nil
    local function map(suffix, rhs, desc)
        if not suffix or suffix == "" then
            return
        end
        vim.keymap.set("n", prefix .. suffix, rhs, {
            buffer = buf,
            desc = "lvim-tex: " .. desc,
            silent = true,
        })
    end

    map(keys.build, COMMANDS.build, "build the document")
    map(keys.continuous, COMMANDS.continuous, "toggle the continuous (rebuild on save) loop")
    map(keys.stop, COMMANDS.stop, "stop this project's build")
    map(keys.stop_all, COMMANDS.stop_all, "stop every build")
    map(keys.clean, function()
        build.clean(0, false)
    end, "clean auxiliary files")
    map(keys.clean_full, function()
        build.clean(0, true)
    end, "clean everything, including the PDF")
    map(keys.errors, COMMANDS.errors, "open the build's quickfix list")
    map(keys.main, COMMANDS.main, "toggle the compile target (root ⇄ subfile)")
    map(keys.info, COMMANDS.info, "project info")
    map(keys.output, COMMANDS.output, "open the build panel")
    map(keys.view, function()
        M.view()
    end, "open the PDF viewer")
    map(keys.reverse, COMMANDS.reverse, "reverse search: jump to what the viewer is showing")
    map(keys.reload, COMMANDS.reload, "reload the project data")
    map(keys.conceal, function()
        conceal.toggle(buf)
    end, "toggle conceal")
    map(keys.imaps, function()
        imaps.list()
    end, "list the maths abbreviations")
    map(keys.outline, COMMANDS.toc, "toggle the table of contents")
    map(keys.files, COMMANDS.files, "find a file in the project")
    map(keys.labels, COMMANDS.labels, "find a label in the project")
    map(keys.cites, COMMANDS.cites, "find a citation in the project")
    map(keys.cite, function()
        require("lvim-tex.cite").open(nil, buf)
    end, "citation actions for the key under the cursor")
    map(keys.count, function()
        require("lvim-tex.count").count(buf)
    end, "count the words in the document")
    map(keys.doc, function()
        require("lvim-tex.doc").doc(nil, buf)
    end, "documentation for the package under the cursor")

    -- Visual mode: the SELECTION compile — the one map that is not normal-mode, so it does not go
    -- through `map` above. It fires while the selection is still up, which is what lvim-tex.selection
    -- expects: it reads the LIVE visual positions, because `'<` / `'>` are only written when visual
    -- mode ends.
    if keys.build_selection and keys.build_selection ~= "" then
        vim.keymap.set("x", prefix .. keys.build_selection, function()
            selection.build()
        end, {
            buffer = buf,
            desc = "lvim-tex: compile the selection as a standalone document",
            silent = true,
        })
    end
end

--- Attach to a TeX buffer: keymaps now, the per-buffer autocmds of later phases here too.
---@param buf integer
---@return nil
local function attach(buf)
    if not api.nvim_buf_is_valid(buf) or vim.b[buf].lvim_tex_attached then
        return
    end
    vim.b[buf].lvim_tex_attached = true
    attach_keys(buf)
    -- Each of these is buffer-local, idempotent, and gates itself on the buffer's own grammar, so a
    -- `bib` buffer installs only what applies to it. `gf` and `%` are UNPREFIXED, which is why the
    -- modules own their maps instead of going through `attach_keys`.
    require("lvim-tex.nav").attach(buf)
    textobjects.attach(buf)
    motion.attach(buf)
    match.attach(buf)
    edit.attach(buf)
    insert.attach(buf)
    syntax.attach(buf)
end

--- Set up lvim-tex. Merges `opts` into the live config, creates `:LvimTex`, and attaches to every
--- TeX buffer (including ones already open when setup runs).
---@param opts LvimTexConfig|table?
---@return nil
function M.setup(opts)
    if ok_utils and utils and utils.merge then
        utils.merge(config, opts)
    elseif opts then
        -- lvim-utils is a hard dependency of the ecosystem; this branch only keeps a bare-bones
        -- install usable long enough for :checkhealth to say what is missing.
        for key, value in pairs(opts) do
            config[key] = value
        end
    end

    augroup = api.nvim_create_augroup("LvimTex", { clear = true })

    -- A second setup() rebuilds every autocmd and timer; the sync link must start clean with them,
    -- or an ownership record and a last-exchanged line from the previous configuration survive into
    -- the new one and silently suppress the first follow that would otherwise have matched.
    require("lvim-tex.synctex").reset()

    -- Conceal owns a WINDOW-scoped effect and therefore its own autocmds (a buffer shown in a second
    -- window is not something a buffer-attach hook can express), exactly as a panel registers itself
    -- with the shared cursor module.
    conceal.setup()

    -- The completion GAP-FILL (K1/K2/K5): one lvim-cmp source for the commands texlab does not
    -- serve. It registers as a fallback for the language server, so it can never double up on it.
    completion.setup()

    -- The maths abbreviations live in lvim-snippets as postfix rules and the snippet collection as an
    -- extra collection root there: both are registrations, not per-buffer state, so they happen once.
    imaps.setup()
    tex_snippets.setup()

    api.nvim_create_autocmd("FileType", {
        group = augroup,
        pattern = config.filetypes,
        desc = "lvim-tex: attach to a TeX buffer",
        callback = function(args)
            attach(args.buf)
        end,
    })

    -- Forward-search after a successful build, when asked for: the viewer then follows what you are
    -- editing with no keystroke. Driven off the PUBLIC event rather than a hook inside the build, so
    -- it is exactly what any other consumer could do.
    api.nvim_create_autocmd("User", {
        group = augroup,
        pattern = "LvimTexBuildDone",
        desc = "lvim-tex: forward-search after a successful build",
        callback = function(args)
            local data = args.data or {}
            if not config.synctex.forward_on_build or data.code ~= 0 or not data.root then
                return
            end
            local buf = api.nvim_get_current_buf()
            if not vim.tbl_contains(config.filetypes, vim.bo[buf].filetype) then
                return
            end
            local pos = api.nvim_win_get_cursor(0)
            viewer.forward(
                data.root,
                fn.fnamemodify(api.nvim_buf_get_name(buf), ":p"),
                pos[1],
                pos[2] + 1,
                function() end
            )
        end,
    })

    -- Follow the CURSOR with the viewer. `CursorMoved` alone would miss a jump made in normal mode
    -- that lands without moving (a `:` command), and `CursorHold` alone waits for 'updatetime' —
    -- which is the user's setting for something else entirely. Both feed the same debounce, so the
    -- cost is one forward search per pause however the cursor got there.
    --
    -- `.bib` is deliberately NOT in the pattern: a bibliography file is read by biber and never by
    -- the engine, so it is in no PDF's SyncTeX data — every follow from one could only spawn a
    -- `synctex` process in order to fail.
    api.nvim_create_autocmd({ "CursorMoved", "CursorHold" }, {
        group = augroup,
        pattern = { "*.tex", "*.ltx" },
        desc = "lvim-tex: keep the viewer on the paragraph the cursor is in",
        callback = function()
            schedule_follow("cursor")
        end,
    })

    -- Follow the SCROLL as well, because reading is scrolling: a mouse wheel, CTRL-E/CTRL-Y or `zz`
    -- moves the view a page away while the cursor stays exactly where it was, and a viewer that only
    -- answers the cursor sits still through all of it. Measured in a TUI: CTRL-E raises `WinScrolled`
    -- and NEITHER `CursorMoved` nor `CursorHold`, so this is a second event or nothing.
    --
    -- REGISTERED WITHOUT A PATTERN on purpose. `WinScrolled` matches its pattern against the WINDOW
    -- ID, not the file name, so `pattern = "*.tex"` (or any path) matches nothing at all and the
    -- autocmd silently never fires — measured: plain 2 firings, file-pattern 0, glob 0. The gate that
    -- the pattern would have expressed lives inside `schedule_follow` instead.
    api.nvim_create_autocmd("WinScrolled", {
        group = augroup,
        desc = "lvim-tex: keep the viewer on the part of the document being read",
        callback = function()
            schedule_follow("scroll")
        end,
    })

    -- A magic `% !TEX root` comment can be added or changed at any time, and the root it names
    -- decides everything else — so the cached answer for THIS buffer is dropped on write.
    api.nvim_create_autocmd("BufWritePost", {
        group = augroup,
        pattern = { "*.tex", "*.ltx", "*.bib" },
        desc = "lvim-tex: re-resolve the root after a write",
        callback = function(args)
            state.buf_root[args.buf] = nil
        end,
    })

    -- The continuous loop's trigger. Deliberately NOT limited to the TeX filetypes: a rebuild is owed
    -- when a `.sty`, a `.cls`, a generated input or an image the document reads changes too — which is
    -- exactly what the watch set (latexmk's own dependency record) knows and a filetype pattern cannot.
    api.nvim_create_autocmd("BufWritePost", {
        group = augroup,
        desc = "lvim-tex: rebuild on save when the continuous loop is armed",
        callback = function(args)
            local path = api.nvim_buf_get_name(args.buf)
            if path ~= "" then
                build.on_write(vim.fs.normalize(vim.fn.fnamemodify(path, ":p")), args.buf)
            end
        end,
    })

    api.nvim_create_user_command("LvimTex", function(cmd)
        local sub = cmd.fargs[1] or "build"
        local handler = COMMANDS[sub]
        if handler then
            handler(cmd.fargs[2])
        else
            local names = vim.tbl_keys(COMMANDS)
            table.sort(names)
            notify(("unknown subcommand %q (%s)"):format(sub, table.concat(names, "|")), vim.log.levels.WARN)
        end
    end, {
        nargs = "*",
        desc = "lvim-tex",
        complete = function(arg, line)
            local words = vim.split(vim.trim(line), "%s+")
            if #words > 2 or (#words == 2 and arg == "") then
                local ARGS = {
                    clean = { "full" },
                    view = { "close" },
                    toc = { "split", "float", "area", "bottom" },
                    conceal = vim.tbl_keys(config.conceal.groups),
                    count = { "file", "selection" },
                    imaps = { "toggle", "on", "off" },
                }
                return ARGS[words[2]] or {}
            end
            local names = vim.tbl_keys(COMMANDS)
            table.sort(names)
            return vim.tbl_filter(function(name)
                return name:find(arg, 1, true) == 1
            end, names)
        end,
    })

    -- Buffers already open when setup runs (a session restore, or a lazy load triggered BY a
    -- .tex buffer) never see the FileType event.
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if api.nvim_buf_is_loaded(buf) and vim.tbl_contains(config.filetypes, vim.bo[buf].filetype) then
            attach(buf)
        end
    end
end

return M
