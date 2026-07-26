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
local rules = require("lvim-tex.log.rules")
local viewer = require("lvim-tex.viewer")

local ok_utils, utils = pcall(require, "lvim-utils.utils")

local api = vim.api
local fn = vim.fn

local M = {}

---@type integer?  the plugin's augroup, created once by setup()
local augroup = nil

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
    local kind = (target == root) and "root document" or "this subfile"
    notify(("%s compile target: %s (%s)"):format(config.icons.section, fn.fnamemodify(target, ":t"), kind))
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
    local engine = root_mod.engine(root)
    local graph = root_mod.graph(root)
    local watch = root_mod.watch(root, project.target, root_mod.out_dir(root))
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
        ("builder   %s%s"):format(root_mod.program(root) or config.builder, engine and (" (" .. engine .. ")") or ""),
        ("out dir   %s"):format(root_mod.out_dir(root)),
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
    map(keys.reload, COMMANDS.reload, "reload the project data")
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
                local ARGS = { clean = { "full" }, view = { "close" } }
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
