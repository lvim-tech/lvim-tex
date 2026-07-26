# lvim-tex

Full LaTeX support for Neovim, built for the lvim-tech ecosystem: root detection, compilation, and
a log parser that turns a TeX transcript into real diagnostics.

lvim-tex owns what is TeX-specific and nothing else. The LSP (texlab), the formatter (latexindent),
the grammars and the snippet engine are already owned by the other lvim-tech layers, so this plugin
concentrates on the document itself — **which file IS the document**, how it is built, what its log
means, and where a position in the PDF maps back to in the source.

> **Status.** Phases 1-4: the project model, builds (one-shot and a save-driven loop), the log →
> diagnostics pipeline, the build panel, the viewer layer with the PDF page as its default viewer, and
> SyncTeX in both directions with the external viewers. The TOC panel, the editing operators, conceal
> and the maths abbreviations land in the phases after them. Everything documented below is implemented and proven;
> nothing is described that does not work yet.

## What it does today

- **Root detection.** Building the chapter you happen to be editing would produce a document with no
  preamble, so every action resolves the root document first, through a chain of increasingly weaker
  evidence: a `% !TEX root =` magic comment (followed transitively), a `\documentclass[main]{subfiles}`
  optional argument, a marker file upward (`.texlabroot`, `texlabroot`, `.latexmkrc` — the same
  markers texlab uses, so the LSP and the builder can never disagree), an upward `\documentclass`
  scan, and finally the file itself.
- **A compile-target toggle.** `,ls` switches between compiling the root and compiling just the
  subfile you are in, and the choice sticks for that project.
- **Builds through latexmk, tectonic, or your own command.** Single-flight: a burst of requests
  collapses into the run in progress plus at most one rerun. A run that outlives `continuous.timeout` is
  killed by a watchdog. `% !TEX program = xelatex` is honoured as an engine flag (latexmk drives every
  engine; tectonic IS its own, so the directive is reported rather than silently ignored).
- **A save-driven rebuild loop**, armed per project with `,la`. A save rebuilds only when the written
  file is one the build actually READS — that comes from latexmk's own dependency record, so a changed
  `.bib`, `.sty` or generated input triggers a rebuild while an unrelated file in the same folder does
  not. A burst of saves debounces into one build. The loop is ours, not latexmk's `-pvc`: scheduling
  stays here and there is no long-lived child process.
- **A build panel** (`,lo`) on the canonical surface: the project facts, the state with its exit code and
  duration, the watch-set size, and the diagnostics grouped by severity — each row naming the LOG RULE
  that produced it, so a wrong verdict is a one-line fix in `diagnostics.rules` rather than a mystery.
  `<CR>` jumps to the entry. A second tab holds the builder's raw output tail.
- **A PDF viewer, driven from the build.** One interface, many implementations; the default is
  lvim-preview's PDF page, which needs no install on any platform and is the only viewer that can show
  what the build is doing: a starting build raises "building" over the last good render, a failed one
  an error strip naming the first error, a successful one refetches the new file. A failed build never
  swaps the render — the page you were reading stays. `,lv` opens it; `viewer.name = "auto"` picks the
  first available of a per-OS list. The external viewers (zathura, sioyek, okular, …) are named in
  that list already: zathura, sioyek, okular and evince on Linux, Skim on macOS, SumatraPDF on Windows.
- **SyncTeX both ways.** `,lv` opens the viewer *and* jumps it to the paragraph under your cursor.
  Ctrl-click in the viewer moves the editor's cursor back to the source that produced it — for the
  default page over lvim-preview's own websocket, for an external viewer through
  `nvim --server … --remote-expr …`, embedded in the launch command, so nothing has to be installed
  (no `nvr`) and no shim script lands on disk. `:checkhealth lvim-tex` names the one manual step each
  viewer still needs, and distinguishes what was verified against a real binary here from what follows
  the viewer's documentation on a platform this machine is not.
- **A statusline chip** (`require("lvim-tex").hud_segment()`) that shows the build state in a TeX buffer
  and the error count when one failed.
- **Diagnostics from the log, attributed correctly.** Entries land on the file they name — usually
  *not* the buffer you built from — and every buffer the previous run wrote to is cleared first, so a
  fixed error disappears. `vim.diagnostic` plus an optional quickfix list.
- **A log rule table.** The parser recognises the generic shapes; per-package meaning is data. Rules
  ship for the LaTeX kernel, hyperref, biblatex/biber/bibtex, babel/polyglossia, the font machinery,
  and the layout packages (pgf/tikz, geometry, microtype, amsmath, caption, float), plus graphics
  (graphicx, the driver `.def`s, xcolor), tables and lists (array, longtable, tabularx, multicol,
  enumitem), code listings (listings, minted), cross-referencing (cleveref, varioref, natbib) and the
  engine itself (inputenc, the TeX capacity limits). A record that
  matches no rule is still reported, attributed to its file — nothing is dropped silently. You add
  coverage with a row, never by editing the parser.
- **Treesitter queries the LaTeX grammar does not ship.** Text objects (environment, command,
  argument, math zone, `\item`, comment), indentation following latexindent's own rules, and code
  injection into `lstlisting` blocks by their `language=` option — the last one folding the case, since
  `listings` treats `language=Python` and `language=python` alike while a parser name is case-sensitive.
- **An include graph and a watch set.** The graph (from the treesitter grammar) is what the TOC, `gf`
  and the pickers will use. The rebuild watch set is read from latexmk's own dependency records —
  `.fls` for what the engine read, `.fdb_latexmk` for what every rule read, which is the only place a
  `.bib` appears at all, since bibliography files are read by biber and never by the engine.

## Requirements

- Neovim 0.11+
- A TeX distribution providing `latexmk` (TeX Live, MacTeX, MiKTeX)
- `lvim-utils` — the shared config merge and helpers
- The `latex` and `bibtex` treesitter grammars, for the include graph (`lvim-ts`'s `ensure_installed`)
- Optional: `lvim-lang`, whose latex provider wires texlab and latexindent

`:checkhealth lvim-tex` reports each of these, plus the project the current buffer belongs to.

## Installation

With **lvim-installer**, or with Neovim's native `vim.pack`:

```lua
vim.pack.add({ "https://github.com/lvim-tech/lvim-tex" })

require("lvim-tex").setup({})
```

## Commands

| Command | What it does |
| --- | --- |
| `:LvimTex build` | Compile the current project's target (the default subcommand) |
| `:LvimTex continuous` | Arm / disarm the save-driven rebuild loop for this project |
| `:LvimTex output` | Open the build panel (facts, diagnostics by severity, raw output) |
| `:LvimTex view` | Open the PDF viewer on this project's output |
| `:LvimTex view close` | Close it |
| `:LvimTex stop` | Stop this project's build |
| `:LvimTex stop_all` | Stop every running build |
| `:LvimTex clean` | Remove the auxiliary files (`latexmk -c`) |
| `:LvimTex clean full` | Also remove the produced PDF (`latexmk -C`) |
| `:LvimTex main` | Toggle the compile target: root document ⇄ the current subfile |
| `:LvimTex errors` | Open the quickfix list of the last build |
| `:LvimTex info` | Report root, target, builder, out dir, include/watch counts, and which rule produced each entry |
| `:LvimTex reload` | Drop the cached project data and re-read it |

## Keymaps

Every map is **buffer-local** to `tex`, `plaintex` and `bib`, and hangs off `<localleader>` — so the
group exists only inside a TeX buffer and the global `<leader>` groups are untouched. With the
default `maplocalleader = ","`, `keys.build` reads `,ll`.

| Key | Action |
| --- | --- |
| `<localleader>ll` | Build |
| `<localleader>la` | Toggle the save-driven rebuild loop for this project |
| `<localleader>lo` | Open the build panel |
| `<localleader>lv` | Open the PDF viewer and jump it to the cursor (forward search) |
| `<localleader>lk` | Stop this build |
| `<localleader>lK` | Stop every build |
| `<localleader>lc` | Clean auxiliary files |
| `<localleader>lC` | Clean everything |
| `<localleader>le` | Open the quickfix list |
| `<localleader>ls` | Toggle the compile target |
| `<localleader>li` | Project info |
| `<localleader>lx` | Reload the project data |

Set any suffix to `false` to leave that key unmapped, or change `keys.prefix` to move the whole group.

## Viewing

The viewer is one interface with many implementations, and the build lifecycle talks to it in terms
of what a viewer can DO rather than which one it is — `reload` is `auto` (the viewer watches the file
itself), `push` (we tell it) or `none`; `status` says whether it can show our build state.

The default, and the only one implemented in this version, is **lvim-preview's PDF page**: it is
already in the ecosystem, works on every platform, needs nothing installed, and is the only viewer
that can render a build state. lvim-tex registers the PDF as an lvim-preview *artifact* before the
first build, so the page can be opened immediately and says "building" instead of failing on a file
that does not exist yet. It is not filesystem-watched on purpose — a build writes its PDF several
times across its reruns, and only the build knows which write was the final, coherent one.

How the page itself behaves — position restore across a reload, lazy rasterisation of long documents,
the forward-search highlight — is lvim-preview's own configuration and is deliberately not mirrored
here: one behaviour, one owner.

`viewer.name = "auto"` takes the first available of `viewer.priority` (per-OS default, preview
first). Naming a viewer explicitly is honoured strictly: if it is missing you get an error, never a
silent substitution.

### SyncTeX

`synctex view` maps a source position to a page and a point, `synctex edit` maps it back; this plugin
is the only thing that speaks to that utility, and a viewer with SyncTeX support of its own is handed
the SOURCE position instead so it resolves it the way it always does.

Inverse search — a click in the viewer moving the cursor here — needs the viewer to be able to reach
this Neovim. It already can: `v:servername` names its socket, so the launch command embeds
`nvim --server <socket> --remote-expr "…inverse_file_line('%f',%l)"` with each viewer's own
placeholders. Nothing extra is installed and nothing is written to disk.

Where it is automatic and where it is not:

| viewer | forward | inverse | verified |
| --- | --- | --- | --- |
| preview (default) | yes | ctrl-click, once lvim-preview's `artifact.allow_client_messages` is on | against the running server |
| zathura | yes, into the window we launched | automatic when we launch it | against the local binary |
| okular | yes (`--unique`, `--noraise`) | automatic when we launch it | against the local binary |
| sioyek | yes | automatic when we launch it | per its documentation; not installed here |
| evince | over D-Bus | not claimed | **experimental** — the interface has not been exercised |
| Skim (macOS) | yes | a one-time setting in Skim's own preferences | per its documentation |
| SumatraPDF (Windows) | yes | automatic when we launch it | per its documentation |

`:checkhealth lvim-tex` prints that matrix for YOUR machine — including the exact lines to paste
where a manual step is unavoidable — and never reports an unproven module as ready.

## Events

Both carry the project data in `args.data`, so a statusline or a panel can react without polling:

- `User LvimTexBuildStart` — `{ root, target, builder }`
- `User LvimTexBuildDone` — `{ root, builder, code, errors, duration }`

## Adding a log rule

A rule is a row. `match` is a Lua pattern (or a predicate) against the message text; `extract` refines
the position and wording, and returning `false` from it drops the record entirely:

```lua
require("lvim-tex").setup({
    diagnostics = {
        rules = {
            {
                id = "mypkg.deprecated",
                pkg = "mypkg",
                match = "is deprecated, use",
                severity = vim.diagnostic.severity.WARN,
                extract = function(rec)
                    local old = rec.text:match("`(.-)'")
                    return { message = ("mypkg: %s is deprecated"):format(old or "?") }
                end,
            },
        },
    },
})
```

User rules are tried **after** the shipped set, so matching the same text overrides the shipped
verdict. `:LvimTex info` names the winning rule per entry, which is what makes a wrong verdict
debuggable.

## Configuration

The full default configuration — every value is an option, and `setup()` merges yours into it in
place, so `require("lvim-tex.config")` always reflects what is in effect:

```lua
require("lvim-tex").setup({
    builder = "latexmk", -- latexmk | tectonic | latexrun | arara | texpresso | custom
    builders = {
        latexmk = {
            bin = "latexmk",
            args = { "-pdf", "-file-line-error", "-interaction=nonstopmode", "-synctex=1" },
            out_dir_flag = "-outdir=%s",
        },
        tectonic = { bin = "tectonic", args = { "--synctex", "--keep-logs" }, out_dir_flag = "--outdir=%s" },
        latexrun = { bin = "latexrun", args = {}, out_dir_flag = "-O=%s" },
        arara = { bin = "arara", args = {}, out_dir_flag = nil },
        texpresso = { bin = "texpresso", args = {}, out_dir_flag = nil },
        custom = { bin = nil, args = {}, out_dir_flag = nil, append_target = true },
    },
    out_dir = "build", -- relative to the root's directory; nil keeps artefacts beside the source
    root = {
        magic_comment = true,
        scan_lines = 5,
        markers = { ".texlabroot", "texlabroot", ".latexmkrc" },
        subfiles = "root", -- root | subfile
    },
    continuous = {
        enabled = true, -- the master switch; arm per project with `,la`
        auto_start = false, -- arm the loop as a project opens
        on_save = true,
        timeout = 120000, -- ms before a wedged build is killed
        debounce = 250, -- ms of quiet after a write before a build starts
    },
    diagnostics = {
        enabled = true,
        warnings = true,
        boxes = false, -- over/underfull boxes
        quickfix = "on_error", -- never | on_error | always
        ignore = {}, -- Lua patterns; a matching message is dropped
        rules = {}, -- extra log rules, appended after the shipped set
    },
    panel = { layout = "float" }, -- the build panel: "float" | "area" | "bottom"
    synctex = {
        bin = "synctex",
        inverse = true, -- let a click in the viewer move the cursor here
        forward_on_build = false, -- forward-search after every successful build
    },
    viewer = {
        enabled = true,
        name = "auto", -- auto | preview | zathura | sioyek | okular | evince | skim | sumatra
        priority = nil, -- nil = the per-OS default order, preview first
        open_on_start = true, -- open the viewer as a build starts
        zathura = { bin = "zathura", args = {} },
        sioyek = { bin = "sioyek", args = {} },
        okular = { bin = "okular", args = {} },
        evince = { bin = "evince", args = {} },
        skim = { displayline = "displayline" },
        sumatra = { bin = "SumatraPDF.exe", args = {} },
    },
    filetypes = { "tex", "plaintex", "bib" },
    notify = true,
    output_lines = 400, -- trailing raw-output lines kept per project
    keys = {
        prefix = "<localleader>l",
        build = "l",
        continuous = "a",
        stop = "k",
        stop_all = "K",
        clean = "c",
        clean_full = "C",
        output = "o",
        errors = "e",
        view = "v",
        reverse = "r",
        outline = "t",
        main = "s",
        info = "i",
        reload = "x",
        imaps = "m",
        cite = "z",
        count = "w",
        doc = "d",
        build_selection = "L",
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
    edit = { delim_modifiers = { { "\\left", "\\right" } } },
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
        warn = "󰀦",
        info = "󰋼",
        hint = "󰌶",
    },
})
```

Keys and options for features that have not landed yet (`view`, `outline`, `imaps`, the editing
operators, …) are present so the shape is stable and does not change under you later; they take
effect as each phase ships.

## License

BSD-3-Clause
