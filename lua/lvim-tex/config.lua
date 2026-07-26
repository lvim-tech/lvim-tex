-- lvim-tex: the live configuration table.
-- Holds the defaults; setup() merges user overrides into it IN PLACE (via lvim-utils.utils.merge),
-- so every require("lvim-tex.config") reader sees the effective values — there is no second copy.
--
-- Two conventions worth knowing before editing this file:
--   • MAXIMAL CONFIGURABILITY — every glyph, timeout, binary name, argv, key and layout is an
--     option here. Nothing user-visible is hardcoded in the modules.
--   • KEYS ARE PREFIX + SUFFIX — `keys.prefix` is the group (<localleader>l, i.e. `,l` with the
--     default maplocalleader), and each command key is the SUFFIX letter appended to it. The maps
--     are buffer-local to the TeX filetypes, so the prefix exists only inside a TeX buffer and can
--     never collide with the global <leader> groups. Set a suffix to `false` to not map it.
--
---@module "lvim-tex.config"

---@class LvimTexBuilder
---@field bin          string?   Executable name (looked up on PATH; nil for `custom` until the user sets it)
---@field args         string[]  Fixed arguments, before the out-dir flag and the file
---@field out_dir_flag string?   Flag used to place output in `out_dir` ("-outdir=%s" style, %s = dir)
---@field append_target boolean?  (custom) append the target file after `args`; false when args name it

---@class LvimTexRootConfig
---@field magic_comment boolean   Honour a `% !TEX root = …` directive in the first lines
---@field scan_lines    integer   How many leading lines are scanned for magic comments
---@field markers       string[]  Marker filenames that pin the project root (aligned with texlab's)
---@field subfiles      "root"|"subfile"  Default compile target when editing an included file

---@class LvimTexDiagnosticsConfig
---@field enabled  boolean   Publish vim.diagnostic entries from the build log
---@field warnings boolean   Include warnings (LaTeX/package), not just errors
---@field boxes    boolean   Include over/underfull box messages (noisy — off by default)
---@field quickfix "never"|"on_error"|"always"  When the quickfix list is opened after a build
---@field ignore   string[]  Lua patterns; a matching message is dropped entirely
---@field rules    table[]   EXTRA log rules appended after the shipped set (see lvim-tex.log)

---@class LvimTexViewerConfig
---@field enabled       boolean   Drive a viewer at all (false = builds only)
---@field name          string    "auto", or one viewer name — a named one is never substituted
---@field priority      string[]? Order tried when `name = "auto"`; nil = the per-OS default list
---@field open_on_start boolean   Open the viewer as a build starts (external ones wait for a PDF)

---@class LvimTexSynctexConfig
---@field bin              string   The `synctex` utility
---@field inverse          boolean  Accept inverse-search requests from a viewer
---@field forward_on_build boolean  Forward-search to the cursor after every successful build

---@class LvimTexConfig
---@field builder      string                        Active builder key into `builders`
---@field builders     table<string, LvimTexBuilder> Per-backend command definitions
---@field out_dir      string?                       Build directory, relative to the root's dir (nil = alongside)
---@field root         LvimTexRootConfig             Main-file detection
---@field continuous   table                         Save-driven rebuild loop (enabled/auto_start/on_save/timeout/debounce)
---@field diagnostics  LvimTexDiagnosticsConfig      Log → vim.diagnostic / quickfix
---@field panel        table                         Build-panel layout ("float"|"area"|"bottom")
---@field viewer       LvimTexViewerConfig           PDF viewer selection and per-viewer argv
---@field synctex      LvimTexSynctexConfig          Forward / inverse search
---@field filetypes    string[]                      Filetypes lvim-tex attaches to
---@field notify       boolean                       Emit vim.notify lines for lifecycle events
---@field output_lines integer                       Trailing raw-output lines kept per project
---@field keys         table                         Buffer-local keymaps (prefix + suffix)
---@field edit         table                         Editing behaviour (the delimiter-modifier list)
---@field icons        table<string, string>         Nerd Font glyphs (all verified single-width)

---@type LvimTexConfig
return {
    -- Active backend: a key of `builders`. Every backend is one module under lvim-tex.build.
    builder = "latexmk",

    -- `-file-line-error` and `-interaction=nonstopmode` are NOT cosmetic: the log parser depends on
    -- the `file:line: message` shape the first flag produces, and the second stops the engine from
    -- blocking on an interactive prompt inside a job with no tty. `-synctex=1` is what makes forward
    -- and inverse search possible at all.
    builders = {
        latexmk = {
            bin = "latexmk",
            args = { "-pdf", "-file-line-error", "-interaction=nonstopmode", "-synctex=1" },
            out_dir_flag = "-outdir=%s",
        },
        tectonic = {
            bin = "tectonic",
            args = { "--synctex", "--keep-logs" },
            out_dir_flag = "--outdir=%s",
        },
        latexrun = { bin = "latexrun", args = {}, out_dir_flag = "-O=%s" },
        arara = { bin = "arara", args = {}, out_dir_flag = nil },
        texpresso = { bin = "texpresso", args = {}, out_dir_flag = nil },
        -- `custom` is the escape hatch: any command, e.g. { bin = "make", args = { "pdf" } }. Set
        -- `append_target = false` when the command already names its file in `args`.
        custom = { bin = nil, args = {}, out_dir_flag = nil, append_target = true },
    },

    -- Output directory, relative to the ROOT document's directory (absolute paths are used as-is).
    -- nil keeps every artefact beside the source, as a bare `latexmk` would.
    out_dir = "build",

    root = {
        magic_comment = true,
        scan_lines = 5,
        -- Same markers texlab roots on, so the LSP and the builder never disagree about the project.
        markers = { ".texlabroot", "texlabroot", ".latexmkrc" },
        subfiles = "root",
    },

    -- The rebuild loop is OUR scheduler, not latexmk's `-pvc`: one build in flight at a time, with
    -- at most one rerun pending, so a burst of saves collapses into "the build that is running" plus
    -- "one more after it" — and there is no long-lived child process to babysit.
    continuous = {
        -- The MASTER switch. Per project the loop is armed with `:LvimTex continuous` (`,la`), so one
        -- document can rebuild on save while another does not; `auto_start` arms it as a panel opens.
        enabled = true,
        auto_start = false,
        on_save = true,
        timeout = 120000, -- ms before a wedged build is killed (watchdog)
        debounce = 250, -- ms of quiet after a write before a build starts
    },

    diagnostics = {
        enabled = true,
        warnings = true,
        boxes = false,
        quickfix = "on_error",
        ignore = {},
        rules = {},
    },

    -- The build panel (`:LvimTex output`, `,lo`). "float" is the centered frame; "area" and "bottom"
    -- dock it, following the ecosystem's layout tokens.
    panel = { layout = "float" },

    -- The PDF viewer. `name = "auto"` takes the first available of `priority` (per-OS default list
    -- when `priority` is nil); naming one explicitly is honoured strictly — a configured viewer that
    -- is missing is an error, never a silent substitution.
    --
    -- How the preview PAGE behaves (position restore across a reload, lazy rasterisation, the
    -- forward-search highlight) is lvim-preview's own configuration and is NOT mirrored here: one
    -- behaviour, one owner.
    viewer = {
        enabled = true,
        name = "auto", -- auto | preview | zathura | sioyek | okular | evince | skim | sumatra
        priority = nil, -- nil = the per-OS default order, preview first
        -- Open the viewer as a build starts (our preview page shows "building" over the last render;
        -- an external viewer waits until there is a PDF to show).
        open_on_start = true,
        zathura = { bin = "zathura", args = {} },
        sioyek = { bin = "sioyek", args = {} },
        okular = { bin = "okular", args = {} },
        evince = { bin = "evince", args = {} },
        skim = { displayline = "displayline" },
        sumatra = { bin = "SumatraPDF.exe", args = {} },
    },

    -- SyncTeX — the two-way map between the source and the PDF. `inverse` governs whether a click in
    -- a viewer may move the cursor here; a viewer still has to be able to reach the editor, which for
    -- our own preview page also needs lvim-preview's `artifact.allow_client_messages` (its setting,
    -- its config — `:checkhealth lvim-tex` prints the line).
    synctex = {
        bin = "synctex",
        inverse = true,
        -- Forward-search to the cursor after every successful build, so the viewer follows what you
        -- are editing without pressing anything.
        forward_on_build = false,
    },

    filetypes = { "tex", "plaintex", "bib" },
    notify = true,

    -- Trailing lines of the builder's raw output kept per project — enough for the build panel and
    -- `:LvimTex info`, never the whole transcript of a large document.
    output_lines = 400,

    keys = {
        -- <localleader> (`,` by default) — NEVER <leader>: `<leader>l` is the global "Code" group.
        -- Buffer-local to `filetypes`, so `,l…` only exists in a TeX buffer.
        prefix = "<localleader>l",
        -- Suffix letters follow vimtex's own set, so the keystrokes transfer 1:1.
        build = "l", -- one-shot build (or continuous toggle, see keys.continuous)
        continuous = "a", -- toggle the save-driven rebuild loop
        stop = "k",
        stop_all = "K",
        clean = "c",
        clean_full = "C",
        output = "o", -- the build panel
        errors = "e", -- quickfix list
        view = "v",
        reverse = "r", -- inverse search from the viewer's position
        outline = "t", -- TOC panel
        main = "s", -- toggle the compile target root ⇄ current subfile
        info = "i",
        reload = "x",
        imaps = "m",
        cite = "z", -- citation action menu
        count = "w",
        doc = "d",
        build_selection = "L", -- visual mode
        -- The editing operators are UNPREFIXED, exactly as in vimtex.
        edit = {
            change_env = "cse",
            delete_env = "dse",
            toggle_star = "tse",
            change_cmd = "csc",
            delete_cmd = "dsc",
            toggle_delim = "tsd",
            toggle_delim_rev = "tsD",
            toggle_frac = "tsf",
            close_env_insert = "]]",
        },
    },

    -- Editing behaviour (the operators themselves land with the editing phase; the shape is fixed
    -- now so it does not change under a user later). `delim_modifiers` is the list the delimiter
    -- toggle cycles through — extend it with sized modifiers (\bigl/\bigr, \Bigl/\Bigr, …).
    edit = { delim_modifiers = { { "\\left", "\\right" } } },

    -- Nerd Font, every glyph verified single-width with strdisplaywidth.
    icons = {
        building = "󰔟",
        ok = "󰄬",
        fail = "󰅚",
        section = "󰉹",
        viewer = "󰈦",
        math = "󰪚",
        cite = "󰧮",
        label = "󰓹",
        count = "󰆙",
        doc = "󰋗",
        toc = "󰠶",
        -- Per-severity glyphs for the build panel's diagnostic rows.
        warn = "󰀦",
        info = "󰋼",
        hint = "󰌶",
    },
}
