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
---@field engine_flag   string?   (latexrun) flag selecting the engine ("--latex-cmd=%s", %s = engine name)
---@field output_flag   string?   (latexrun) flag naming the produced PDF ("-o=%s", %s = absolute path)
---@field clean_flag    string?   (latexrun) its single clean action ("--clean-all")
---@field distribution  string?   (texpresso) "auto" | "texlive" | "tectonic" — where it finds packages
---@field include_paths string[]? (texpresso) extra TeX input paths, each passed as `-I <path>`

---@class LvimTexRootConfig
---@field magic_comment boolean   Honour a `% !TEX root = …` directive in the first lines
---@field scan_lines    integer   How many leading lines are scanned for magic comments
---@field markers       string[]  Marker filenames that pin the project root (aligned with texlab's)
---@field subfiles      "root"|"subfile"  Default compile target when editing an included file
---@field build_on_toggle boolean   `:LvimTex main` builds the new target when it has no PDF yet

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

---@class LvimTexOutlineConfig
---@field layout        "split"|"float"|"area"|"bottom"  How the TOC opens ("split" = a persistent dock)
---@field position      "left"|"right"  Which side the docked layout takes
---@field width         number   Fraction of the columns (or an absolute count > 1)
---@field follow        boolean  Track the section the source cursor is in
---@field auto_close    boolean  A jump closes the panel
---@field fold_level    integer  Fold to this sectioning depth on open (0 = everything open)
---@field max_level     integer  Deepest sectioning level shown (part 1 … subparagraph 7)
---@field todo_keywords string[] Comment keywords that become TODO rows
---@field show          table<string, boolean>  Which row kinds start visible
---@field keys          table    Buffer-local keys inside the panel

---@class LvimTexNavConfig
---@field extensions     table<string, string[]>  Extensions tried per include kind, in order
---@field kpsewhich      string?  The TeX-distribution lookup used for \usepackage / \documentclass
---@field create_missing boolean  Offer to create a TeX include that does not exist yet

---@class LvimTexSynctexConfig
---@field bin              string   The `synctex` utility
---@field inverse          boolean  Accept inverse-search requests from a viewer
---@field forward_on_build boolean  Forward-search to the cursor after every successful build
---@field follow_cursor    boolean  Keep the viewer on the paragraph the cursor is in, as it moves
---@field follow_debounce  integer  ms of stillness before a follow-up forward search is sent

---@class LvimTexConcealConfig
---@field enabled   boolean                  Conceal is on for a TeX buffer as soon as it is opened
---@field level     integer                  `conceallevel` while a TeX buffer is displayed (2 = replace)
---@field cursor    string                   `concealcursor`: modes in which the CURSOR line stays concealed
---@field groups    table<string, boolean>   Which conceal groups are drawn
---@field math_only table<string, boolean>   Per group: conceal only inside a maths zone
---@field maps      table<string, table>     User character maps, merged OVER the shipped ones

---@class LvimTexImapsConfig
---@field enabled  boolean                Register the maths abbreviations at setup()
---@field leader   string                 The character that starts an abbreviation
---@field mappings table<string, string>  Your abbreviations, merged OVER the shipped set
---@field disable  string[]               Shipped triggers to drop entirely

---@class LvimTexSnippetsConfig
---@field enabled boolean  Register the shipped `tex` snippet collection with lvim-snippets

---@class LvimTexConfig
---@field builder      string                        Active builder key into `builders`
---@field builders     table<string, LvimTexBuilder> Per-backend command definitions
---@field out_dir      string|false                  Build directory, relative to the root's dir (false = alongside)
---@field root         LvimTexRootConfig             Main-file detection
---@field continuous   table                         Save-driven rebuild loop (enabled/auto_start/on_save/timeout/debounce)
---@field diagnostics  LvimTexDiagnosticsConfig      Log → vim.diagnostic / quickfix
---@field panel        table                         Build-panel layout ("float"|"area"|"bottom")
---@field viewer       LvimTexViewerConfig           PDF viewer selection and per-viewer argv
---@field synctex      LvimTexSynctexConfig          Forward / inverse search
---@field conceal      LvimTexConcealConfig          Treesitter conceal: symbols, scripts, delimiters
---@field imaps        LvimTexImapsConfig            Insert-mode maths abbreviations (E9)
---@field snippets     LvimTexSnippetsConfig         The shipped snippet collection (E10)
---@field outline      LvimTexOutlineConfig          The table-of-contents panel
---@field nav          LvimTexNavConfig              Resolving an include to a file (`gf`)
---@field filetypes    string[]                      Filetypes lvim-tex attaches to
---@field notify       boolean                       Emit vim.notify lines for lifecycle events
---@field output_lines integer                       Trailing raw-output lines kept per project
---@field keys         table                         Buffer-local keymaps (prefix + suffix)
---@field selection    table                         Visual-selection compile (scratch dir, suffix, viewer, timeout)
---@field textobjects  table                         Text objects (E1): { enabled }
---@field motion       table                         Structural motions (E2): { enabled }
---@field fold         table                         Treesitter folding for TeX buffers (S6)
---@field indent       table                         Query indentation (S7): { enabled, keys }
---@field matchparen   table                         Matching-pair highlight (S8)
---@field edit         table                         Editing behaviour (the delimiter-modifier list)
---@field cite         table                         Citation action menu (K8): URL templates, fields, register
---@field count        table                         Word count (M2): texcount binary, args, per-file rows
---@field docs         table                         Package documentation (M1): texdoc binary and args
---@field completion   table                         Completion gap-fill (K1/K2/K5): the commands texlab misses
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
        -- latexrun keeps EVERY intermediate file in its object directory (`-O`, which it hands the
        -- engine as -output-directory, so the .log/.synctex.gz/.fls land there) and copies only the
        -- finished PDF to `-o`. Both are named explicitly because its own defaults — `latex.out` and
        -- the current directory — are not where the log parser and `root.pdf` look. latexrun already
        -- passes `-interaction nonstopmode -recorder` itself; `-file-line-error` (the shape the log
        -- parser keys on) and `-synctex=1` are not, so they go in `--latex-args`: ONE word, which
        -- latexrun splits with POSIX shell rules.
        latexrun = {
            bin = "latexrun",
            args = { "--latex-args=-file-line-error -synctex=1" },
            out_dir_flag = "-O=%s",
            output_flag = "-o=%s",
            engine_flag = "--latex-cmd=%s",
            clean_flag = "--clean-all",
        },
        -- arara does what the DOCUMENT's `% arara: …` directives say: the engine, the rerun count and
        -- the bibliography tool are all in the file, so there is nothing to configure here. It has no
        -- output-directory option at all (hence no out_dir_flag) and no clean action.
        arara = { bin = "arara", args = {}, out_dir_flag = nil },
        -- texpresso is an engine AND a viewer in one long-lived process: it writes no PDF, produces no
        -- log and never exits, so it is NOT a batch build (see lvim-tex.build.texpresso).
        -- `distribution` selects the -texlive / -tectonic flag; "auto" passes neither.
        texpresso = {
            bin = "texpresso",
            args = {},
            out_dir_flag = nil,
            distribution = "auto",
            include_paths = {},
        },
        -- `custom` is the escape hatch: any command, e.g. { bin = "make", args = { "pdf" } }. Set
        -- `append_target = false` when the command already names its file in `args`.
        custom = { bin = nil, args = {}, out_dir_flag = nil, append_target = true },
    },

    -- Output directory, relative to the ROOT document's directory (absolute paths are used as-is).
    -- `false` keeps every artefact beside the source, as a bare `latexmk` would — which is what a
    -- project whose `.gitignore` lists `*.aux` / `main.pdf` at its root expects.
    --
    -- It is `false`, not `nil`, ON PURPOSE: a `nil` value in a Lua table is an ABSENT key, so
    -- `setup({ out_dir = nil })` cannot override a non-empty default — it merges nothing at all.
    out_dir = "build",

    root = {
        magic_comment = true,
        scan_lines = 5,
        -- Same markers texlab roots on, so the LSP and the builder never disagree about the project.
        markers = { ".texlabroot", "texlabroot", ".latexmkrc" },
        subfiles = "root",
        -- `:LvimTex main` is what a user reaches for in order to compile something ELSE, so when the
        -- new target has no PDF yet, build it. The alternative is a toggle that reports "save to build
        -- it" and waits — a save of a file nobody changed, purely to make the tool act.
        -- An existing PDF is shown as it is; the next save rebuilds it like any other target.
        build_on_toggle = true,
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

    -- Text objects (E1) — buffer-local, mapped in operator-pending and visual mode only. The
    -- selections come from the queries this plugin ships (after/queries/latex/textobjects.scm).
    textobjects = { enabled = true },

    -- Structural motions (E2) — section / environment / math-zone / \item boundaries.
    motion = { enabled = true },

    -- Treesitter folding for TeX buffers (S6). The latex query bundle ships `folds.scm`, so this is
    -- a gate, not an implementation — and a per-language one: lvim-ts's own fold switch is global.
    -- `level` is the initial 'foldlevel' (high = the document opens unfolded).
    fold = { enabled = false, level = 99 },

    -- Query indentation (S7): the queries are ours (after/queries/latex/indents.scm), the engine is
    -- lvim-ts's. `keys` is the 'indentkeys' value — the `0=\end`-style entries are what make a
    -- closing line pull back onto its opener AS IT IS TYPED, not only under `=`.
    -- `enabled = false` means lvim-tex leaves 'indentexpr' alone; lvim-ts applies the same query on
    -- its own when installed, and turning THAT off is lvim-ts's own option.
    indent = {
        enabled = true,
        keys = "!^F,o,O,0{,0},0],0=\\end,0=\\right,0=\\item,0=\\bibitem",
    },

    -- The matching-pair highlight (S8). Off by default: `%` jumping works without it, and a second
    -- highlight over Neovim's own matchparen is a taste decision. `:LvimTex matchparen` toggles it.
    matchparen = { enabled = false, highlight = "MatchParen", priority = 150 },

    -- The table of contents (`:LvimTex toc`, `,lt`). "split" is a PERSISTENT panel docked beside the
    -- document — the only layout in which follow-the-cursor is live, because it is the only one the
    -- source cursor keeps moving under. "float"/"area"/"bottom" open the same tree as a modal on the
    -- shared tabs chassis. Every key and every default row toggle is an option.
    outline = {
        layout = "split", -- split | float | area | bottom
        position = "right",
        width = 0.28,
        follow = true,
        auto_close = true, -- a jump closes the panel
        fold_level = 0, -- 0 = open at full depth; 2 = parts and chapters only
        max_level = 7, -- part 1, chapter 2, section 3 … subparagraph 7
        todo_keywords = { "TODO", "FIXME", "XXX", "HACK", "NOTE" },
        -- Labels are OFF by default: a document with a label per equation would bury its own sections.
        show = { includes = true, labels = false, todos = true, numbers = true },
        keys = {
            activate = "<CR>", -- jump (always — `l` is the expand-or-jump of the shared tree)
            expand = "l",
            collapse = "h",
            peek = "o", -- jump but keep the cursor in the panel
            fold_more = "-",
            fold_less = "+",
            levels = { "1", "2", "3", "4", "5", "6", "7" }, -- fold TO that depth
            expand_all = "zR",
            collapse_all = "zM",
            toggle_includes = "i",
            toggle_labels = "r",
            toggle_todos = "d",
            toggle_numbers = "n",
            filter = "s",
            actions = "a", -- the per-row action menu
            refresh = "R",
            help = "g?",
            close = "q",
        },
    },

    -- Resolving an include to a file. The extension list is per include KIND, because the command
    -- decides it: `\input` names a .tex, `\includegraphics` any of the graphics formats, and a
    -- `\usepackage` names a .sty that lives in the TeX distribution — which only kpsewhich can find.
    nav = {
        extensions = {
            tex = { "", ".tex", ".ltx" },
            graphics = { "", ".pdf", ".png", ".jpg", ".jpeg", ".eps", ".ps", ".svg", ".gif" },
            bib = { "", ".bib" },
            class = { "", ".cls" },
            package = { "", ".sty" },
            style = { "", ".bst" },
        },
        kpsewhich = "kpsewhich", -- nil disables the distribution lookup
        create_missing = true, -- `gf` on a TeX include that does not exist offers to create it
    },

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
        -- Keep the VIEWER on what you are editing: after the cursor has been still for
        -- `follow_debounce` ms, the page is moved to the paragraph it sits in. Only ever while a
        -- viewer is already open — this never opens one — and only when the PDF has SyncTeX data for
        -- that file, so it is silent in a buffer that was not part of the last build.
        --
        -- Debounced rather than per-move on purpose: each follow is a `synctex` process, and typing
        -- through a paragraph would otherwise spawn one per keystroke.
        follow_cursor = false,
        follow_debounce = 400,
    },

    -- Conceal — the source rendered as the maths it means, drawn from the parse tree onto the VISIBLE
    -- rows only (ephemeral extmarks in a decoration provider), so a 2000-line document costs the same
    -- as a 50-line one. `level`/`cursor` are set with `:setlocal` semantics while a TeX buffer is
    -- displayed, so `conceallevel` everywhere else in the editor is untouched.
    --
    -- `groups` says WHAT is drawn, `math_only` says WHERE (a `\alpha` in prose is a typo, not a
    -- symbol — but an accent is legitimate everywhere), and `maps` is merged OVER the shipped
    -- character tables in lvim-tex.conceal.data: a user entry for a command replaces the shipped one
    -- and every command the user did not name keeps its glyph.
    conceal = {
        enabled = false,
        level = 2, -- 2 = the replacement character; 1 = a placeholder; 0 = off
        cursor = "nc", -- modes where the CURSOR line stays concealed ("" = always reveal it)
        groups = {
            math_symbols = true, -- \alpha -> α, \sum -> ∑, \le -> ≤
            scripts = true, -- x^{2n} -> x²ⁿ  (all or nothing per script)
            delimiters = true, -- \left( -> (, \langle -> ⟨
            accents = true, -- \'{e} -> é, \hat{a} -> â
            styles = true, -- \textbf{x} -> x (highlighted), \mathbb{R} -> ℝ
            refs = true, -- \ref{k} -> 󰓹k, \cite{k} -> 󰧮k
            sections = false, -- \section{T} -> 󰉹T
        },
        math_only = {
            math_symbols = true,
            scripts = true,
            delimiters = true,
            accents = false,
            styles = false,
            refs = false,
            sections = false,
        },
        maps = {},
    },

    -- Insert-mode MATHS abbreviations (E9): `leader` + a mnemonic, expanded the moment it is typed
    -- and ONLY inside a maths zone (the same treesitter answer conceal uses), so `@a` in prose stays
    -- the two characters that were typed. The MECHANISM is lvim-snippets' postfix engine — lvim-tex
    -- registers one rule per abbreviation there — so lvim-snippets must be installed with its
    -- `postfix.enabled` left on; `:checkhealth lvim-tex` reports both halves.
    --
    -- `mappings` merges OVER the shipped table (lvim-tex.imaps.data): a trigger you name replaces the
    -- shipped one, every other keeps its meaning, and `disable` drops shipped triggers entirely.
    -- ONE RULE when adding your own: no trigger may be a PREFIX of another — with no accept key the
    -- shorter always fires first, so the longer could never be reached. `:checkhealth lvim-tex` names
    -- any pair that breaks it. `j`, `J`, `K`, `M`, `O`, the digits 1-5/7/9 and the symbols `&`, `#`,
    -- `_`, `:`, `;`, `?` are unassigned on purpose, so they are free to claim.
    imaps = {
        enabled = false,
        -- A BACKTICK, matching the tool this plugin replaces, so the abbreviations transfer with the
        -- rest of the keys (the G1 zero-relearn ruling). It is safe despite `\`word'` being LaTeX's
        -- opening quote: an abbreviation only expands inside a MATHS zone, where that quote form does
        -- not occur.
        leader = "`",
        mappings = {},
        disable = {},
    },

    -- The shipped `tex` snippet collection (E10): document skeletons, environments, maths constructs,
    -- references. It is registered with lvim-snippets as an extra collection ROOT, scanned after your
    -- own `paths`, so it can never outrank or replace them. false leaves it unregistered.
    snippets = { enabled = true },

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
        conceal = "n", -- toggle conceal (or one group: `:LvimTex conceal scripts`)
        imaps = "m", -- list the maths abbreviations (and toggle them from the footer)
        cite = "z", -- citation action menu
        count = "w",
        doc = "d",
        files = "f", -- find a file in the project
        labels = "g", -- find a \label in the project
        cites = "b", -- find a bibliography entry
        -- The file jump is UNPREFIXED: it replaces the built-in `gf`, which cannot resolve a TeX
        -- include (no extension, root-relative, \graphicspath). Not on an include → the built-in runs.
        -- Jump between \begin/\end, \left/\right and the math bounds (S8/N5). Not on a delimiter →
        -- the built-in `%` runs, so brackets keep working exactly as before.
        match = "%",
        -- Text objects: the effective key is `outer`/`inner` .. the kind's suffix (`ae`, `i$`, …).
        -- Set a suffix to `false` to leave that object unmapped.
        textobjects = {
            outer = "a",
            inner = "i",
            environment = "e",
            command = "c",
            math = "$",
            delimiter = "d",
            item = "m",
            parameter = "a",
            comment = "%",
        },
        -- Motions, in normal + visual + operator-pending, count-aware (`3]m`).
        motion = {
            section_next = "]]",
            section_prev = "[[",
            section_end_next = "][",
            section_end_prev = "[]",
            env_next = "]m",
            env_prev = "[m",
            env_end_next = "]M",
            env_end_prev = "[M",
            math_next = "]n",
            math_prev = "[n",
            math_end_next = "]N",
            math_end_prev = "[N",
            item_next = "]i",
            item_prev = "[i",
        },
        goto_file = "gf",
        goto_file_split = "<C-w>f",
        goto_file_vsplit = "<C-w>gf",
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
    -- `,lL` in visual mode: compile the SELECTION as a document of its own, reusing the ROOT's
    -- preamble verbatim in a scratch project (lvim-tex.selection documents what that does and does
    -- not carry over).
    selection = {
        -- Where the scratch projects live. nil = a per-project folder under stdpath("cache"), keyed
        -- by a digest of the root's path so two projects called main.tex never share one.
        dir = nil,
        -- Appended to the root's name for the generated document (main → main-selection.tex).
        suffix = "-selection",
        -- Show the produced PDF in the configured viewer, exactly as a normal build would.
        view = true,
        -- ms before a wedged snippet build is killed; nil follows continuous.timeout.
        timeout = nil,
    },

    edit = {
        -- The E6 cycle: none → 1 → 2 → … → none. With one entry `tsd` toggles \left(…\right) on and
        -- off; extend it with sized modifiers (\bigl/\bigr, \Bigl/\Bigr, …) to cycle through them.
        delim_modifiers = { { "\\left", "\\right" } },
        -- Delimiter pairs the toggle recognises when there is no \left…\right node yet. Pairs whose
        -- two delimiters are equal (`|…|`) cannot be nested unambiguously and are skipped.
        delimiters = {
            { "(", ")" },
            { "[", "]" },
            { "\\{", "\\}" },
            { "\\langle", "\\rangle" },
            { "\\lfloor", "\\rfloor" },
            { "\\lceil", "\\rceil" },
        },
        -- Environments the operators never target: `document` wraps every buffer, so without this
        -- `cse`/`dse`/`tse` outside a real environment would silently rewrite \begin{document}.
        ignore_environments = { "document" },
        -- E7: which commands count as a fraction, which one is produced, and the inline operator.
        frac_commands = { "frac", "dfrac", "tfrac", "cfrac" },
        frac_command = "frac",
        frac_separator = "/",
        -- E8 (`]]` in insert mode): with the cursor at the end of the line that OPENS an environment,
        -- leave a blank, one-step-deeper body line and put the cursor on it — where the next
        -- character goes. false writes the `\begin` / `\end` pair with nothing between.
        close_env_body = true,
        -- E8: how a `\left X` that is still open gets closed. `delimiters` above already pairs the
        -- nestable ones; these exist ONLY to be closed — symmetric pairs (which the toggle skips,
        -- because `|…|` cannot be nested unambiguously) and the ones too rare to cycle through.
        close_delimiters = {
            { ".", "." },
            { "|", "|" },
            { "\\|", "\\|" },
            { "\\vert", "\\vert" },
            { "\\Vert", "\\Vert" },
            { "<", ">" },
            { "\\lgroup", "\\rgroup" },
            { "\\lmoustache", "\\rmoustache" },
            { "\\uparrow", "\\uparrow" },
            { "\\downarrow", "\\downarrow" },
        },
    },

    -- K8: the citation ACTION menu (`,lz`, `:LvimTex cite [key]`) — where a key's DOI, its URL, its
    -- attached PDF and its bibliography entry live. The URL templates are options so a DOI proxy or
    -- an institutional resolver is one line away.
    cite = {
        doi_url = "https://doi.org/%s",
        arxiv_url = "https://arxiv.org/abs/%s",
        -- Which bibliography FIELDS each action reads, in order — the first non-empty one wins. A
        -- bibliography that keeps its links somewhere else needs one more name here, not a patch.
        fields = {
            doi = { "doi" },
            url = { "url", "howpublished" },
            file = { "file", "pdf" },
            arxiv = { "eprint" },
        },
        -- Where "yank the key" puts it.
        yank_register = "+",
    },

    -- M2: the word count. `-inc` is what makes it the DOCUMENT's count (texcount follows \input and
    -- \include itself); `:LvimTex count file` drops it for a single file.
    count = {
        bin = "texcount",
        args = { "-inc" },
        per_file = true, -- list every counted file under the totals
        timeout = 30000,
    },

    -- M1: package documentation. `list_args` is the RESOLVING form — it prints the manuals texdoc
    -- would open instead of opening them, which is how health and `:LvimTex doc` check a package
    -- exists before handing it to a viewer.
    docs = {
        bin = "texdoc",
        args = {},
        list_args = { "-l" },
        timeout = 15000,
    },

    -- K1-K6: completion is texlab's (through lvim-lang), and this block is ONLY the gap-fill for the
    -- commands texlab's providers do not recognise — measured against a multi-file, multi-bib
    -- fixture on 2026-07-26 with texlab 5.26.0. Everything else — \cite, \ref, \gls, \acrshort,
    -- \begin, \usepackage, \input, \includegraphics — texlab answers in full, and this source never
    -- fires there: `fallback_for` makes lvim-cmp run it only after the server has answered with
    -- nothing at all, so the day texlab learns one of these commands, this stops firing on it.
    completion = {
        enabled = true,
        priority = 55,
        fallback_for = { "lsp" },
        trigger_chars = { "{", "," },
        -- The commands to serve, per data set. Each list is exactly what texlab returned NOTHING for.
        commands = {
            citations = { "Citep", "Citet" },
            labels = { "nameref", "Nameref", "cpageref", "Cpageref", "autopageref", "vpageref", "subref" },
            glossary = {
                "glsentrytext",
                "glsentryname",
                "glsentrydesc",
                "glsentryfirst",
                "glsentryplural",
                "glsentrysymbol",
                "glsxtrshort",
                "glsxtrlong",
                "glsadd",
            },
        },
        -- Glossary DEFINITIONS beyond the two the grammar has nodes for (\newglossaryentry and
        -- \newacronym): the glossaries-extra spellings, matched by command name.
        glossary_definitions = { "longnewglossaryentry", "newabbreviation", "glsxtrnewsymbol", "newterm" },
        -- Commands that load a file of glossary entries; the scan follows them.
        glossary_loaders = { "loadglsentries" },
    },

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
        include = "󰈙",
        graphics = "󰋩",
        bib = "󱉟",
        todo = "󰄱",
    },
}
