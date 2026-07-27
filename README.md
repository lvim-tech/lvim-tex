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
  subfile you are in, and the choice sticks for that project. Everything that has to follow the target
  does: a target with no PDF yet is **built** right there (`root.build_on_toggle`), one that has a PDF is
  **shown** (a closed viewer is opened when `viewer.open_on_start` allows it), an already-open viewer is
  re-pointed at the new file — our own page in place, keeping its URL and its tab — and the ENGINE is
  inherited from the root, since a `% !TEX program` directive lives in a preamble the subfile does not
  have. On a book this is the one real speed lever: the
  preamble's font machinery is a fixed cost every compile pays, and everything above it scales with how
  much text you hand the engine.
- **Builds through latexmk, tectonic, latexrun, arara, or your own command.** Single-flight: a burst of requests
  collapses into the run in progress plus at most one rerun. A run that outlives `continuous.timeout` is
  killed by a watchdog. `% !TEX program = xelatex` is honoured as an engine flag (latexmk drives every
  engine; tectonic IS its own, so the directive is reported rather than silently ignored).
- **A save-driven rebuild loop**, armed per project with `,la` — or from the start with
  `continuous.auto_start = true`, which is the closest thing to what a `-pvc` watch mode gives you. A save rebuilds only when the written
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
| `:LvimTex reverse` | Ask the viewer which page it shows and jump the cursor there |
| `:LvimTex view close` | Close it |
| `:'<,'>LvimTex selection` | Compile the selection as a standalone document |
| `:LvimTex stop` | Stop this project's build |
| `:LvimTex stop_all` | Stop every running build |
| `:LvimTex clean` | Remove the compile TARGET's auxiliary files (`latexmk -c`) |
| `:LvimTex clean full` | Also remove its PDF (`latexmk -C`) |
| `:LvimTex clean this` | The file in the buffer, whatever the target is (`full` too) |
| `:LvimTex clean all` | Every `.tex` the project's include graph names (`full` too) |
| `:LvimTex main` | Toggle the compile target: root document ⇄ the current subfile |
| `:LvimTex errors` | Open the quickfix list of the last build |
| `:LvimTex info` | Report root, target, builder, out dir, include/watch counts, and which rule produced each entry |
| `:LvimTex toc [layout]` | Toggle the table of contents (`split`, `float`, `area`, `bottom`) |
| `:LvimTex files` | Find a file in the project |
| `:LvimTex labels` | Find a `\label` in the project |
| `:LvimTex cites` | Find a citation in the project |
| `:LvimTex imaps [on\|off\|toggle]` | List the maths abbreviations, or switch them |
| `:LvimTex cite [key]` | Citation actions: DOI, URL, attached PDF, jump to the entry, yank the key |
| `:LvimTex count [file\|selection]` | Word count through `texcount` |
| `:LvimTex doc [package]` | Package documentation through `texdoc` |
| `:LvimTex conceal` | Toggle conceal for this buffer |
| `:LvimTex conceal <group>` | Toggle one conceal group everywhere |
| `:LvimTex matchparen` | Toggle the matching-pair highlight |
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
| `<localleader>lm` | List the maths abbreviations |
| `<localleader>lz` | Citation actions for the key under the cursor |
| `<localleader>lw` | Word count |
| `<localleader>ld` | Documentation for the package under the cursor |
| `<localleader>ln` | Toggle conceal |
| `<localleader>lt` | Toggle the table of contents |
| `<localleader>lf` | Find a file in the project |
| `<localleader>lg` | Find a `\label` in the project |
| `<localleader>lb` | Find a citation in the project |
| `gf` | Jump into the include under the cursor (`<C-w>f`, `<C-w>gf` for splits) |
| `<localleader>lv` | Open the PDF viewer and jump it to the cursor (forward search) |
| `<localleader>lr` | Reverse search: jump the cursor to what the viewer is showing |
| `<localleader>lk` | Stop this build |
| `<localleader>lK` | Stop every build |
| `<localleader>lc` | Clean the compile target's auxiliary files |
| `<localleader>lC` | …and its PDF |
| `<localleader>lh` | Clean **here** — the file in the buffer, whatever the target is |
| `<localleader>lH` | …and its PDF |
| `<localleader>lp` | **Purge** the project — every file its include graph names |
| `<localleader>lP` | …and their PDFs |
| `<localleader>le` | Open the quickfix list |
| `<localleader>ls` | Toggle the compile target |
| `<localleader>li` | Project info |
| `<localleader>lx` | Reload the project data |
| `<localleader>lL` | *(visual)* Compile the selection as a standalone document |

Set any suffix to `false` to leave that key unmapped, or change `keys.prefix` to move the whole group.

## Builders

`builder` names one of `latexmk` (the default), `tectonic`, `latexrun`, `arara` or `custom`.

- **latexmk** — owns the rerun loop; a `% !TEX program` engine directive becomes a latexmk flag.
- **tectonic** — one binary, no distribution. `--synctex --keep-logs` are not optional here: the log
  *is* the diagnostics source.
- **latexrun** — keeps every intermediate in its object directory and copies only the finished PDF out,
  so lvim-tex names both explicitly and the log, the SyncTeX data and the PDF land where everything
  else looks. It has exactly **one** clean action, so `:LvimTex clean` and `:LvimTex clean full` both
  remove the PDF.
- **arara** — runs the workflow the *document* declares in its own `% arara:` directives: the engine,
  the rerun count and the bibliography tool are chosen in the file, not here. arara has **no output
  directory**, and lvim-tex already builds beside the source for it; set `out_dir = false` to make
  the rest of the project match — `:checkhealth` says so. A document with
  no directive fails, which is arara reporting that it had nothing to run.
- **custom** — any command; the build lifecycle applies unchanged. It must leave `<jobname>.log` where
  lvim-tex looks or diagnostics stay empty.

**texpresso** has a config entry and a health probe but is *not* a batch build: it is an engine and a
viewer in one long-lived process that writes no PDF, produces no log and never exits. Selecting it as
`builder` is refused with that explanation rather than left to time out. Its live session — its own
window, its own protocol, its own diagnostics — is separate work and is not implemented.

## Compiling a selection

`,lL` in visual mode (or `:'<,'>LvimTex selection`) compiles the selected text as a document of its
own, reusing the **root document's preamble** — everything from `\documentclass` to `\begin{document}`,
copied verbatim — in a scratch project under `stdpath("cache")`, and opens the result in your viewer.
The run's TeX search paths point back at the project, so a preamble that says `\input{macros}`,
`\usepackage{mylocal}` or `\addbibresource{refs.bib}` still resolves. Errors are reported against
*your* line in *your* file.

What that means in practice: a package the preamble does not load is not guessed for you — the snippet
fails exactly as the real document would. Anything defined after `\begin{document}` (a `\newcommand` in
the body, a counter, a `\label` elsewhere) does not exist in the snippet, so references outside the
selection render as `??`. The selection must be balanced: half a `figure` is not a document. Class
options carry over, so a `twocolumn` class lays the snippet out in two columns too.

## Conceal

`\sum_{i=1}^{n} \alpha_i \le \left( \beta \right)` reads as `∑ᵢ₌₁ⁿ αᵢ ≤ (β)` while the file on disk stays
exactly what you typed. Turn it on with `:LvimTex conceal` (`,ln`), or set `conceal.enabled = true` to
open every TeX buffer concealed.

What is drawn comes from the **parse tree**, not from patterns: a `\alpha` inside a `verbatim` body, a
`%` comment or an `lstlisting` is not a command to the grammar, so it is never touched. The cost of
that choice, stated plainly: while an edit leaves a region unparseable, the concealment there is
briefly stale.

| Group | Draws | Maths only |
| --- | --- | --- |
| `math_symbols` | `\alpha` → α, `\sum` → ∑, `\le` → ≤, `\to` → → | yes |
| `scripts` | `x^{2n}` → `x²ⁿ`, `a_i` → `aᵢ` | yes |
| `delimiters` | `\left(` → `(`, `\left\langle` → `⟨`, `\bigl[` → `[` | yes |
| `accents` | `\'{e}` → é, `\"o` → ö, `\hat{a}` → â | no |
| `styles` | `\textbf{x}` → x (highlighted), `\mathbb{R}` → ℝ | no |
| `refs` | `\ref{k}` → `󰓹k`, `\cite{k}` → `󰧮k` | no |
| `sections` | `\section{T}` → `󰉹T` (off by default) | no |

`:LvimTex conceal <group>` toggles one group everywhere, live.

A script is concealed only when **every** character of it has a Unicode script form — `x^{2n}` becomes
`x²ⁿ`, `x^{2q}` is left alone, because Unicode has no superscript `q` and half-lowered text reads worse
than the source. Accents follow the same rule: only combinations that exist precomposed (which is why
there is no `\vec`).

`conceal.level` and `conceal.cursor` are `conceallevel` and `concealcursor`, set with `:setlocal`
semantics while a TeX buffer is displayed — your `conceallevel` in every other buffer is untouched, and
turning conceal off puts back exactly the value that was there. The default `cursor = "nc"` keeps the
cursor line concealed in normal and command mode and reveals it in insert and visual mode; `cursor = ""`
always reveals the line you are on.

### Your own characters

`conceal.maps` is merged **over** the shipped tables, per group: an entry for a command replaces the
shipped one, every command you do not name keeps its glyph.

```lua
require("lvim-tex").setup({
    conceal = {
        enabled = true,
        maps = {
            math_symbols = { ["\\alpha"] = "A", ["\\myop"] = "⨁" },
            refs = { ["\\label"] = "󰓹" }, -- \label is not concealed by default
            styles = { ["\\textsc"] = "@markup.strong" },
            accents = { ["\\'"] = { y = "ý" } },
        },
    },
})
```

A `styles` entry is either a **highlight group** (the wrapper is hidden and the argument painted with
it — conceal can replace a range with a character but cannot make text bold) or a **letter table**
(`\mathbb` → `{ R = "ℝ", … }`, the whole command becomes one glyph). `accents` entries are always letter
tables.

### Cost

Conceal is drawn from a decoration provider with **ephemeral** extmarks, over the visible rows only, and
the marks a row needs are memoised against the buffer's changedtick — so repainting an unchanged screen
computes nothing. Measured on a 2000-line all-maths document (48-row window, ~24 marks per row,
min/median of 7 passes): +3.8 ms per full-page redraw, +1.2 ms per one-line scroll, +0.78 ms per cursor
move — of which 0.08 ms is the floor of having an active provider at all. With conceal off, the provider
costs 0.012 ms per redraw: the same as not having one.

## Completion

Completion is **texlab's**, wired by lvim-lang — cite keys from every bibliography the document loads
(with the formatted reference in the docs float), `\label`s with what they label, commands and
environments with the package they come from, package and class names from the whole TeX tree with
their CTAN description, glossary and acronym keys, and file paths for every include command. All of it
cross-file.

lvim-tex adds **only** what texlab does not answer, measured command by command: the `\glsentry…`
family (plus `\glsxtrshort`, `\glsxtrlong`, `\glsadd`), `\nameref` / `\cpageref` / `\autopageref` /
`\vpageref` / `\subref`, and natbib's `\Citep` / `\Citet`. That is one lvim-cmp source registered as a
**fallback for the language server**, so it runs only where the server returned nothing — it cannot
double up, and it stops firing on a command the day texlab learns it. `completion.commands` is the
list; `completion.enabled = false` turns it off.

`,lz` opens the **citation actions** for the key under the cursor: open its DOI or URL, open the PDF
its `file` field points at, jump to the entry in the `.bib`, or yank the key. `,lw` reports the
document's word count through `texcount` (following `\input` itself, so it is the whole document's
count, not the file's), and `,ld` opens a package's documentation through `texdoc`.

## Editing

Text objects (operator-pending + visual), from the treesitter queries lvim-tex ships:

| key | object |
| --- | --- |
| `ae` / `ie` | environment (`\begin{x} … \end{x}`) |
| `ac` / `ic` | command with its arguments / the argument list |
| `a$` / `i$` | math zone (`$…$`, `\[…\]`, math environments) |
| `ad` / `id` | delimiter pair (`\left…\right`, brace / bracket groups) |
| `am` / `im` | one `\item` |
| `aa` / `ia` | one argument group |
| `a%` | a comment |

The cursor only has to be inside the OBJECT, not inside the part being selected — `ic` works with the
cursor on `\frac`. Repeating an object in visual mode expands it to the next enclosing instance, and
the objects dot-repeat as operator arguments (`dae` then `.`).

Motions (normal, visual and operator-pending, count-aware): `]]` `[[` next / previous section, `][`
`[]` its end, `]m` `[m` `]M` `[M` environment boundaries, `]n` `[n` `]N` `[N` math zones, `]i` `[i` the
next / previous `\item`.

`%` jumps between `\begin` and `\end`, `\left` and `\right`, and the two ends of a math zone or a
brace / bracket group — resolved from the parse tree, so an `\end{…}` inside a verbatim block or a
comment is never mistaken for the closer. With the cursor on anything else the built-in `%` runs.
`matchparen.enabled` (off by default) additionally highlights both delimiters; `:LvimTex matchparen`
toggles it at runtime.

Operators, unprefixed:

| key | action |
| --- | --- |
| `cse` | change the surrounding environment (both ends, one undo step) |
| `dse` | delete the surrounding environment, keeping its body |
| `tse` | toggle the starred form (environment, command, or a sectioning command on its heading row) |
| `csc` | rename the surrounding command, keeping its arguments |
| `dsc` | delete the surrounding command, keeping its first argument's contents |
| `tsd` / `tsD` | cycle the delimiter modifiers forward / backward (`(…)` ⇄ `\left(…\right)`) |
| `tsf` | toggle `\frac{a}{b}` ⇄ an inline division (operands parenthesised only when compound) |

Folding and indentation are delegated: the folds come from the latex query bundle through
`vim.treesitter.foldexpr` (`fold.enabled` applies them to TeX buffers alone), and the indent from the
lvim-ts query engine over the `indents.scm` this plugin ships — `indent.keys` is what re-indents a
`\end{…}` as it is typed. `indent.enabled = false` means lvim-tex leaves `indentexpr` alone; lvim-ts
applies the same query on its own when it is installed.

lvim-tex also registers the `tex`/`plaintex` → `latex` and `bib` → `bibtex` parser mapping, which
Neovim does not ship — without it nothing that resolves a grammar from the FILETYPE (folding,
treesitter highlighting, the query indent) works in a TeX buffer.

## Maths abbreviations

With `imaps.enabled`, a leader (a backtick, as in the tool this replaces) plus a short mnemonic expands
the moment it is typed — `` `a `` → `\alpha`, `` `ve `` → `\varepsilon`, `` `-> `` → `\to`, `` `o+ `` →
`\oplus`, `` `R `` → `\mathbb{R}` — and **only inside maths**: in prose, in a comment, in a verbatim body
or inside the `\text{}` of a formula, the two characters typed stay text. The zone comes from the parse
tree (the same answer conceal uses), so an unterminated `$x` `` `a `` still counts as maths.

93 abbreviations ship in 8 groups. `:LvimTex imaps` (`,lm`) lists them all — keystrokes, the LaTeX, the
glyph, the group — and toggles the feature from the window's footer; `:LvimTex imaps on|off|toggle`
does the same from the command line. `imaps.mappings` merges over the shipped table and
`imaps.disable` drops entries.

**No trigger may be a prefix of another.** They auto-expand, so the shorter always fires first and the
longer could never be reached; `:checkhealth lvim-tex` names any pair that breaks it. `j`, `J`, `K`,
`M`, `O`, the digits 1-5/7/9 and `&`, `#`, `_`, `:`, `;`, `?` are unassigned on purpose.

This needs lvim-snippets: lvim-tex registers one postfix rule per abbreviation there rather than
running a second insert-mode watcher of its own.

### Closing an environment while typing

`]]` in insert mode writes the `\end` of the innermost environment that is still open, or the `\right`
of an open `\left` delimiter — read from the parse tree, so a `\begin` inside a verbatim body is never
a candidate, and standing inside a complete environment does nothing instead of writing a second
`\end`. A delimiter closes inline; an environment closes on its own line, indented like its `\begin`,
with a blank body line left under a just-typed `\begin{…}` (`edit.close_env_body`). With nothing open
the key types itself, exactly as `%` and `gf` fall back to the built-ins.

### Snippets

lvim-tex ships a `tex` collection (71 snippets: document skeletons, sectioning with labels,
environments, maths constructs, references, formatting) and registers it with lvim-snippets as an extra
collection root — scanned *after* your own `paths`, so it never outranks or replaces them. It completes
through lvim-cmp and lists like any other collection; `snippets.enabled = false` opts out.

Rule of thumb: anything with an argument or limits (`\frac`, `\sum_{}^{}`, an environment) is a
snippet, a bare symbol is an abbreviation.

## Structure and navigation

`:LvimTex toc` (`,lt`) opens the table of contents: every section of the document, across every file
it includes, nested by its real depth — a `\section` written in a chapter sits under the `\chapter`
written in the root. Section numbers are computed (so they are right before the first build), and the
include, `\label` and TODO-comment rows sit in their places. The panel follows the cursor, jumps
(`<CR>`), peeks (`o`), folds by depth (`-`/`+`, `1`-`7`), toggles each row kind (`i` includes, `r`
labels, `d` todos, `n` numbering), filters (`s`), and offers a per-row action menu (`a`). `g?` lists
every key. It opens as a dock beside the document by default; `:LvimTex toc float` (or `area` /
`bottom`) opens the same tree as a modal.

`gf` jumps into whatever include the cursor is on — `\input`, `\include`, `\subfile`, `\import`,
`\includegraphics`, `\addbibresource`, `\usepackage`. The extension is guessed per command, the path is
searched in the current file's directory, then the root's (what LaTeX itself resolves against), then
every `\graphicspath` directory; a package or class falls through to `kpsewhich`. When the file does
not exist, lvim-tex says which candidates it tried — and offers to create a missing chapter.

Three project-wide finders: `:LvimTex files` (`,lf`), `:LvimTex labels` (`,lg`) and `:LvimTex cites`
(`,lb`) — the include graph, every `\label` with the section it sits under, and the bibliography's
entries plus every cited key nothing defines.

## Viewing

The viewer is one interface with many implementations, and the build lifecycle talks to it in terms
of what a viewer can DO rather than which one it is — `reload` is `auto` (the viewer watches the file
itself), `push` (we tell it) or `none`; `status` says whether it can show our build state.

The default is **lvim-preview's PDF page**: it is
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

One source line has ONE SyncTeX anchor, so a paragraph that wraps over several typeset lines is marked
at the line TeX recorded rather than at each of them, and a blank line — typeset as nothing — is
resolved to the nearest line that does put something on the page (downwards first) instead of being
asked about directly, which would answer with whatever node happens to be closest, pages away.

The link works in BOTH directions with the default viewer. `synctex.follow_back` moves the SOURCE
when you scroll the PDF page: the page reports which point of which page is at the top of its
viewport, `synctex edit` turns that into a file and a line, and the window already showing that file
scrolls to it. Only our own page can do this — it is the only viewer that reports where its reader
is — and it needs the same lvim-preview gate as ctrl-click inverse search
(`artifact.allow_client_messages`).

**Or ask, instead of being followed.** `,lr` (`:LvimTex reverse`) is the reverse of `,lv`: it asks the
viewer which page it is showing and jumps the cursor there. One keystroke, no timers, no polling —
and it works whether or not the automatic poll below is on, because that switch decides whether the
editor follows *by itself*, and asking is always allowed. For every external viewer this is the
finest reverse direction there is; ctrl-click answers "the source of THIS", `,lr` answers "the source
of what I am looking at" without leaving the keyboard.

**An external viewer can follow too, by the page.** Our own page is the only viewer that reports a
POSITION; zathura and okular publish which PAGE they are showing and announce nothing when it
changes, so `follow_back.poll` asks them on a timer and moves the source a page's worth when you flip
one. It is off by default — coarse, and a whole-page jump is a surprising thing to opt into silently.

**How precise it can be.** SyncTeX records one anchor per source LINE, and in prose that is usually
one whole paragraph — so the reverse direction resolves to the paragraph you are reading, not to the
sentence. Mid-page that is a few tens of PDF points; it cannot be sharpened by this plugin, because
the data does not carry it. What the plugin does guarantee is that the answer is about the paragraph
in front of you: a report whose resolved line turns out to sit on another page, or further than
`follow_back.tolerance` from the point that produced it, is dropped rather than acted on.

Three rules keep a two-way link usable rather than a fight, and they are the ones lvim-preview's
markdown scroll link already established: it moves the **view and not the cursor** (scrolling is
reading, not editing), it **never focuses or opens** a window — a file you are not looking at is not
moved at all — and whoever moved the other side last **owns the link** for `follow_back.settle` ms,
so the echo of our own forward search is dropped instead of bouncing back. That last one is why the
two directions do not chase each other; it breaks the loop by construction rather than damping it.

`synctex.follow_cursor` keeps the viewer on what you are editing: after the cursor has been still for
`follow_debounce` ms, the page moves to the paragraph it sits in. **A scroll counts as movement too**
(`synctex.follow_scroll`): reading is scrolling, and a wheel, `CTRL-E`/`CTRL-Y` or `zz` moves the view
while leaving the cursor exactly where it was — so a viewer that only ever answers the cursor sits
still through the whole of it. A scroll is answered with the window CENTRE rather than the cursor,
because the cursor is no longer where you are looking. It never opens a viewer — it only
moves one that is already open — and it is silent when the PDF has no SyncTeX data for that file, so a
buffer that was not part of the last build costs nothing. `synctex.forward_on_build` does the same once
per successful build instead of per pause.

**It also never takes the keyboard focus**, and that is what decides which viewers it can drive at all.
A forward search you ASKED for (`,lv`) may raise the viewer's window — that is half of what you asked
for. One sent automatically may not: being pulled out of the buffer a fraction of a second after every
pause, with nothing on screen to explain it, is worse than not following. Some viewers can be told
(okular's `--noraise`, sioyek's `--nofocus`, Skim's `displayline -g`) and some cannot — evince's D-Bus
`SyncView` and Sumatra's `-forward-search` always present their window. So each viewer declares whether
its forward search is `quiet` or `raises`, the cursor-follow drives only the quiet ones, and
`:checkhealth lvim-tex` says which is which on your machine.

zathura sits between the two, and that is why a viewer spec may override the declaration: its raise is
a *setting* (`dbus-raise-window`, on by default), not a property of the binary. `viewer.zathura.forward
= "quiet"` turns it off — over zathura's own `ExecuteCommand`, the one D-Bus call exempt from the
raise — in the instance lvim-tex launched, leaving your zathurarc alone. The trade is all-or-nothing:
after that no sync raises zathura, the explicit `,lv` included.

Where it is automatic and where it is not:

| viewer | forward | follows the cursor | inverse | verified |
| --- | --- | --- | --- | --- |
| preview (default) | yes | yes | ctrl-click, once lvim-preview's `artifact.allow_client_messages` is on | against the running server |
| zathura | yes, into the window we launched | only with `zathura = { forward = "quiet" }` — it raises its window otherwise | automatic when we launch it | against the local binary |
| okular | yes (`--unique`, `--noraise`) | yes | automatic when we launch it | against the local binary |
| sioyek | yes (`--reuse-window`, `--nofocus`) | yes | automatic when we launch it | its flags against a real binary; behaviour not yet watched |
| evince | over D-Bus | no — `SyncView` always raises its window | not claimed (its `SyncSource` signal needs a monitor process) | against the local binary |
| Skim (macOS) | yes (`displayline -g`) | yes | a one-time setting in Skim's own preferences | per its documentation |
| SumatraPDF (Windows) | yes | no — `-forward-search` always raises its window | automatic when we launch it | per its documentation |

A SINGLE-INSTANCE viewer (okular, sioyek) needs one more thing to follow anything: knowing that its
window is still open. It cannot be answered by the process we spawned, because a second invocation
hands its file to the running window and exits within a fraction of a second — so for okular the
question goes to the session bus (`org.kde.okular` → `currentDocument()`), asked behind a short cache
so it stays free on every cursor pause.

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
        latexrun = {
            bin = "latexrun",
            args = { "--latex-args=-file-line-error -synctex=1" },
            out_dir_flag = "-O=%s",
            output_flag = "-o=%s",
            engine_flag = "--latex-cmd=%s",
            clean_flag = "--clean-all",
        },
        arara = { bin = "arara", args = {}, out_dir_flag = nil },
        texpresso = { bin = "texpresso", args = {}, out_dir_flag = nil, distribution = "auto", include_paths = {} },
        custom = { bin = nil, args = {}, out_dir_flag = nil, append_target = true },
    },
    out_dir = "build", -- relative to the root's directory; false keeps artefacts beside the source
    root = {
        magic_comment = true,
        scan_lines = 5,
        markers = { ".texlabroot", "texlabroot", ".latexmkrc" },
        subfiles = "root", -- root | subfile
        build_on_toggle = true, -- `,ls` builds the new target when it has no PDF yet
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
    textobjects = { enabled = true },
    motion = { enabled = true },
    fold = { enabled = false, level = 99 },
    indent = {
        enabled = true,
        keys = "!^F,o,O,0{,0},0],0=\\end,0=\\right,0=\\item,0=\\bibitem",
    },
    matchparen = { enabled = false, highlight = "MatchParen", priority = 150 },
    outline = {
        layout = "split", -- split | float | area | bottom
        position = "right",
        width = 0.28,
        follow = true,
        auto_close = true,
        fold_level = 0, -- 0 = open at full depth
        max_level = 7, -- part 1, chapter 2, section 3 … subparagraph 7
        todo_keywords = { "TODO", "FIXME", "XXX", "HACK", "NOTE" },
        show = { includes = true, labels = false, todos = true, numbers = true },
        keys = {
            activate = "<CR>",
            expand = "l",
            collapse = "h",
            peek = "o",
            fold_more = "-",
            fold_less = "+",
            levels = { "1", "2", "3", "4", "5", "6", "7" },
            expand_all = "zR",
            collapse_all = "zM",
            toggle_includes = "i",
            toggle_labels = "r",
            toggle_todos = "d",
            toggle_numbers = "n",
            filter = "s",
            actions = "a",
            refresh = "R",
            help = "g?",
            close = "q",
        },
    },
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
        create_missing = true,
    },
    selection = {
        dir = nil, -- nil = a per-project folder under stdpath("cache")
        suffix = "-selection", -- main.tex → main-selection.tex
        view = true, -- show the compiled selection in the viewer
        timeout = nil, -- nil follows continuous.timeout
    },
    synctex = {
        bin = "synctex",
        inverse = true, -- let a click in the viewer move the cursor here
        forward_on_build = false, -- forward-search after every successful build
        follow_cursor = false, -- keep the viewer on the paragraph the cursor is in
        follow_scroll = true, -- …and on what a SCROLL brought into view (only while follow_cursor)
        follow_debounce = 400, -- ms of stillness before that follow-up search is sent
        -- The same link the other way: scrolling the PDF page moves the source to the text you are
        -- looking at. Our own preview page only (the one viewer that reports where its reader is),
        -- and it needs lvim-preview's `artifact.allow_client_messages`, as ctrl-click does.
        follow_back = {
            enabled = true,
            settle = 300, -- ms one side owns the link after it moved the other
            -- "center" matches what the page reports (the text at its viewport ANCHOR, its centre by
            -- default — a page's top edge is margin, where SyncTeX has nothing to resolve).
            place = "center", -- where the resolved line lands: "top" | "center"
            -- PDF points the answer may be off before the report is thrown away: one extra
            -- `synctex view` checks where the resolved line REALLY sits. 0 disables the check.
            tolerance = 200,
            -- The COARSE half, for a viewer that can only say which PAGE it is on (zathura, okular
            -- — neither announces a page change, so it is a poll or nothing). Off by default: a
            -- whole-page jump of the source on every page flip is opt-in.
            poll = {
                enabled = false,
                interval = 1000, -- ms between reads (a read costs ~3 ms)
                x = 300, -- where on the page to resolve, PDF points from its top-left —
                y = 396, -- inside the text block of both A4 and letter, never a margin
            },
            move = "view", -- "view" scrolls the window; "cursor" takes the cursor there too
        },
    },
    viewer = {
        enabled = true,
        name = "auto", -- auto | preview | zathura | sioyek | okular | evince | skim | sumatra
        priority = nil, -- nil = the per-OS default order, preview first
        open_on_start = true, -- open the viewer as a build starts
        -- Any viewer spec may carry `forward = "quiet" | "raises" | false` to OVERRIDE what its
        -- module declares about taking the focus on a sync. zathura is why it exists: it presents its
        -- window on every D-Bus command (`--synctex-forward` included) unless its own
        -- `dbus-raise-window` is off, so it does not follow the cursor by default. Set "quiet" and
        -- lvim-tex turns that option off in the window IT opens — your zathurarc is untouched — at the
        -- cost that no sync raises zathura any more, `,lv` included.
        -- Every viewer spec also takes `forward = "quiet" | "raises" | false`, overriding what its
        -- module declares about taking the keyboard focus on a sync. Not shown as a default because
        -- `nil` in a table literal stores nothing.
        zathura = {
            bin = "zathura",
            args = {},
            raise_retries = 16, -- how persistently `dbus-raise-window` is turned off after a launch …
            raise_retry_ms = 250, -- … and how long between attempts (its bus name appears late)
        },
        sioyek = { bin = "sioyek", args = {} },
        okular = { bin = "okular", args = {} },
        evince = { bin = "evince", args = {} },
        skim = { displayline = "displayline", args = {} },
        sumatra = { bin = "SumatraPDF.exe", args = {} },
    },
    conceal = {
        enabled = false,
        level = 2,
        cursor = "nc",
        groups = {
            math_symbols = true,
            scripts = true,
            delimiters = true,
            accents = true,
            styles = true,
            refs = true,
            sections = false,
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
    imaps = {
        enabled = false,
        leader = "`",
        mappings = {},
        disable = {},
    },
    snippets = { enabled = true },
    filetypes = { "tex", "plaintex", "bib" },
    notify = true,
    output_lines = 400, -- trailing raw-output lines kept per project
    keys = {
        prefix = "<localleader>l",
        build = "l",
        continuous = "a",
        stop = "k",
        stop_all = "K",
        clean = "c", -- the compile TARGET's auxiliary files
        clean_full = "C", -- …and its PDF
        clean_here = "h", -- the file in the buffer, whatever the target is
        clean_here_full = "H",
        clean_all = "p", -- every .tex the project's include graph names
        clean_all_full = "P",
        output = "o",
        errors = "e",
        view = "v",
        reverse = "r", -- jump to what the viewer is showing (the reverse of `view`)
        outline = "t",
        main = "s",
        info = "i",
        reload = "x",
        conceal = "n",
        imaps = "m",
        cite = "z",
        count = "w",
        doc = "d",
        files = "f",
        labels = "g",
        cites = "b",
        match = "%",
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
    edit = {
        delim_modifiers = { { "\\left", "\\right" } },
        delimiters = {
            { "(", ")" },
            { "[", "]" },
            { "\\{", "\\}" },
            { "\\langle", "\\rangle" },
            { "\\lfloor", "\\rfloor" },
            { "\\lceil", "\\rceil" },
        },
        ignore_environments = { "document" },
        frac_commands = { "frac", "dfrac", "tfrac", "cfrac" },
        frac_command = "frac",
        frac_separator = "/",
        close_env_body = true,
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
    cite = {
        doi_url = "https://doi.org/%s",
        arxiv_url = "https://arxiv.org/abs/%s",
        fields = {
            doi = { "doi" },
            url = { "url", "howpublished" },
            file = { "file", "pdf" },
            arxiv = { "eprint" },
        },
        yank_register = "+",
    },
    count = { bin = "texcount", args = { "-inc" }, per_file = true, timeout = 30000 },
    docs = { bin = "texdoc", args = {}, list_args = { "-l" }, timeout = 15000 },
    completion = {
        enabled = true,
        priority = 55,
        fallback_for = { "lsp" },
        trigger_chars = { "{", "," },
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
        glossary_definitions = { "longnewglossaryentry", "newabbreviation", "glsxtrnewsymbol", "newterm" },
        glossary_loaders = { "loadglsentries" },
    },
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
        include = "󰈙",
        graphics = "󰋩",
        bib = "󱉟",
        todo = "󰄱",
    },
})
```

Keys and options for features that have not landed yet (`view`, `outline`, `imaps`, the editing
operators, …) are present so the shape is stable and does not change under you later; they take
effect as each phase ships.

## License

BSD-3-Clause
