# lvim-tex

Full LaTeX support for Neovim, built for the lvim-tech ecosystem: root detection, compilation, and
a log parser that turns a TeX transcript into real diagnostics.

lvim-tex owns what is TeX-specific and nothing else. The LSP (texlab), the formatter (latexindent),
the grammars and the snippet engine are already owned by the other lvim-tech layers, so this plugin
concentrates on the document itself — **which file IS the document**, how it is built, what its log
means, and where a position in the PDF maps back to in the source.

> **Status.** This is phase 1 of the plugin: the project model, the one-shot build, and the log →
> diagnostics pipeline. The continuous rebuild loop, the viewer/SyncTeX layer, the TOC panel, the
> editing operators, conceal and the maths abbreviations land in the phases after it. Everything
> documented below is implemented and proven; nothing is described that does not work yet.

## What it does today

- **Root detection.** Building the chapter you happen to be editing would produce a document with no
  preamble, so every action resolves the root document first, through a chain of increasingly weaker
  evidence: a `% !TEX root =` magic comment (followed transitively), a `\documentclass[main]{subfiles}`
  optional argument, a marker file upward (`.texlabroot`, `texlabroot`, `.latexmkrc` — the same
  markers texlab uses, so the LSP and the builder can never disagree), an upward `\documentclass`
  scan, and finally the file itself.
- **A compile-target toggle.** `,ls` switches between compiling the root and compiling just the
  subfile you are in, and the choice sticks for that project.
- **One-shot builds through latexmk.** Single-flight: a burst of requests collapses into the run in
  progress plus at most one rerun. A run that outlives `continuous.timeout` is killed by a watchdog.
  `% !TEX program = xelatex` is honoured as an engine flag.
- **Diagnostics from the log, attributed correctly.** Entries land on the file they name — usually
  *not* the buffer you built from — and every buffer the previous run wrote to is cleared first, so a
  fixed error disappears. `vim.diagnostic` plus an optional quickfix list.
- **A log rule table.** The parser recognises the generic shapes; per-package meaning is data. Rules
  ship for the LaTeX kernel, hyperref, biblatex/biber/bibtex, babel/polyglossia, the font machinery,
  and the layout packages (pgf/tikz, geometry, microtype, amsmath, caption, float). A record that
  matches no rule is still reported, attributed to its file — nothing is dropped silently. You add
  coverage with a row, never by editing the parser.
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
| `<localleader>lk` | Stop this build |
| `<localleader>lK` | Stop every build |
| `<localleader>lc` | Clean auxiliary files |
| `<localleader>lC` | Clean everything |
| `<localleader>le` | Open the quickfix list |
| `<localleader>ls` | Toggle the compile target |
| `<localleader>li` | Project info |
| `<localleader>lx` | Reload the project data |

Set any suffix to `false` to leave that key unmapped, or change `keys.prefix` to move the whole group.

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
        custom = { bin = nil, args = {}, out_dir_flag = nil },
    },
    out_dir = "build", -- relative to the root's directory; nil keeps artefacts beside the source
    root = {
        magic_comment = true,
        scan_lines = 5,
        markers = { ".texlabroot", "texlabroot", ".latexmkrc" },
        subfiles = "root", -- root | subfile
    },
    continuous = {
        enabled = true,
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
    },
})
```

Keys and options for features that have not landed yet (`view`, `outline`, `imaps`, the editing
operators, …) are present so the shape is stable and does not change under you later; they take
effect as each phase ships.

## License

BSD-3-Clause
