; lvim-tex: LaTeX text objects.
; The latex query bundle ships folds/highlights/injections only — there is no upstream
; `textobjects.scm` at all, so this file is entirely ours. Capture names follow the
; nvim-treesitter-textobjects convention so any shared textobject layer picks them up:
;
;   @class.*      an environment  \begin{x} … \end{x}
;   @function.*   a command       \cmd[opt]{arg}…
;   @parameter.*  one argument group / one key=value option of a command
;   @block.*      a delimited zone: math ($…$, \[…\], math environments),
;                 a \left…\right delimiter pair, and plain {…} / […] groups
;   @statement.*  one \item entry of an itemize/enumerate/description list
;   @comment.outer  line/block comments and the `comment` environment
;
; Two mechanisms produce the `inner` ranges, both built into Neovim (no
; `#make-range!` — that is a nvim-treesitter-textobjects extension, and using it would
; make this file fail to compile under a plain `vim.treesitter.query.parse`):
;
;   * `#offset!` where the delimiters have a FIXED width — `{`/`}`, `[`/`]`, `$`,
;     `\[`/`\]`. That yields one exact node range, so it works with any consumer.
;   * an anchored quantified wildcard (`. _+ @x .`) where the delimiter width varies —
;     the `\begin{…}`/`\end{…}` pair, `\left(`/`\right)`, `\item`, a command's argument
;     list. The grammar has no `body` node for any of those, so the body can only be
;     named as "every sibling between the two delimiters". `_` (not `(_)`) is required:
;     math bodies interleave anonymous tokens (`=`, `^`, `_`) with named ones, and an
;     anchor treats those as a break, so `(_)+` silently matches nothing there.

; ---------------------------------------------------------------------------
; ENVIRONMENT — \begin{x} … \end{x}
; ---------------------------------------------------------------------------
; outer: the whole environment, \begin and \end included.
[
  (generic_environment)
  (math_environment)
  (comment_environment)
  (listing_environment)
  (verbatim_environment)
  (minted_environment)
  (pycode_environment)
  (sagesilent_environment)
  (sageblock_environment)
  (luacode_environment)
  (asy_environment)
  (asydef_environment)
] @class.outer

; inner: the body — everything between `begin` and `end`.
(generic_environment
  begin: (_)
  .
  _+ @class.inner
  .
  end: (_))

; A math environment is both a class (an environment) and a block (a math zone).
(math_environment
  begin: (_)
  .
  _+ @class.inner @block.inner
  .
  end: (_))

; Code / verbatim environments carry their body as ONE leaf, so the inner is exact.
[
  (listing_environment
    code: (source_code) @class.inner)
  (minted_environment
    code: (source_code) @class.inner)
  (pycode_environment
    code: (source_code) @class.inner)
  (sagesilent_environment
    code: (source_code) @class.inner)
  (sageblock_environment
    code: (source_code) @class.inner)
  (luacode_environment
    code: (source_code) @class.inner)
  (asy_environment
    code: (source_code) @class.inner)
  (asydef_environment
    code: (source_code) @class.inner)
  (verbatim_environment
    verbatim: (comment) @class.inner)
]

; ---------------------------------------------------------------------------
; COMMAND — \cmd[opt]{arg}
; ---------------------------------------------------------------------------
; outer: the command token plus every argument group that belongs to it. Besides the
; catch-all `generic_command`, the grammar gives the commands it knows their own node
; type, and those are commands too.
[
  (generic_command)
  (class_include)
  (package_include)
  (latex_include)
  (verbatim_include)
  (graphics_include)
  (svg_include)
  (inkscape_include)
  (import_include)
  (bibtex_include)
  (bibstyle_include)
  (biblatex_include)
  (label_definition)
  (label_reference)
  (label_reference_range)
  (label_number)
  (citation)
  (hyperlink)
  (caption)
  (text_mode)
  (new_command_definition)
  (old_command_definition)
  (let_command_definition)
  (environment_definition)
  (theorem_definition)
  (paired_delimiter_definition)
  (glossary_entry_definition)
  (acronym_definition)
  (color_definition)
] @function.outer

; inner: the argument list — everything after the leading command token.
[
  (generic_command . _ . _+ @function.inner)
  (class_include . _ . _+ @function.inner)
  (package_include . _ . _+ @function.inner)
  (latex_include . _ . _+ @function.inner)
  (verbatim_include . _ . _+ @function.inner)
  (graphics_include . _ . _+ @function.inner)
  (svg_include . _ . _+ @function.inner)
  (inkscape_include . _ . _+ @function.inner)
  (import_include . _ . _+ @function.inner)
  (bibtex_include . _ . _+ @function.inner)
  (bibstyle_include . _ . _+ @function.inner)
  (biblatex_include . _ . _+ @function.inner)
  (label_definition . _ . _+ @function.inner)
  (label_reference . _ . _+ @function.inner)
  (label_reference_range . _ . _+ @function.inner)
  (label_number . _ . _+ @function.inner)
  (citation . _ . _+ @function.inner)
  (hyperlink . _ . _+ @function.inner)
  (caption . _ . _+ @function.inner)
  (text_mode . _ . _+ @function.inner)
  (new_command_definition . _ . _+ @function.inner)
  (old_command_definition . _ . _+ @function.inner)
  (let_command_definition . _ . _+ @function.inner)
  (environment_definition . _ . _+ @function.inner)
  (theorem_definition . _ . _+ @function.inner)
  (paired_delimiter_definition . _ . _+ @function.inner)
  (glossary_entry_definition . _ . _+ @function.inner)
  (acronym_definition . _ . _+ @function.inner)
  (color_definition . _ . _+ @function.inner)
]

; A command with no arguments is nothing but its name, so `if` falls back to the whole
; node — that keeps `cif` / `dif` usable on e.g. `\newpage` or `\\`.
((generic_command) @function.inner
  (#not-lua-match? @function.inner "[{%[]"))

; ---------------------------------------------------------------------------
; PARAMETER — one argument group, or one key=value inside an option group
; ---------------------------------------------------------------------------
(generic_command
  arg: (_) @parameter.outer)

((generic_command
  arg: (_) @parameter.inner)
  (#offset! @parameter.inner 0 1 0 -1))

(key_value_pair) @parameter.outer

(key_value_pair
  value: (_) @parameter.inner)

; ---------------------------------------------------------------------------
; MATH ZONE — $…$, \(…\), \[…\], $$…$$  (math environments are handled above)
; ---------------------------------------------------------------------------
[
  (inline_formula)
  (displayed_equation)
  (math_environment)
] @block.outer

; `$…$`: one-character delimiters.
((inline_formula) @block.inner
  (#lua-match? @block.inner "^%$[^%$]")
  (#offset! @block.inner 0 1 0 -1))

; `\(…\)` and `$$…$$`: two-character delimiters — as is every `displayed_equation`
; opener, which is either `\[` or `$$`.
((inline_formula) @block.inner
  (#not-lua-match? @block.inner "^%$[^%$]")
  (#offset! @block.inner 0 2 0 -2))

((displayed_equation) @block.inner
  (#offset! @block.inner 0 2 0 -2))

; ---------------------------------------------------------------------------
; DELIMITER PAIR — \left( … \right) and plain brace / bracket groups
; ---------------------------------------------------------------------------
(math_delimiter) @block.outer

; The delimiter after \left is not fixed-width (`(`, `\{`, `\langle`, …), so the body
; is the run of siblings between the two delimiter commands.
(math_delimiter
  left_delimiter: _
  .
  _+ @block.inner
  .
  right_command: _)

[
  (curly_group)
  (curly_group_author_list)
  (curly_group_command_name)
  (curly_group_glob_pattern)
  (curly_group_impl)
  (curly_group_key_value)
  (curly_group_label)
  (curly_group_label_list)
  (curly_group_path)
  (curly_group_path_list)
  (curly_group_spec)
  (curly_group_text)
  (curly_group_text_list)
  (curly_group_uri)
  (curly_group_value)
  (curly_group_word)
  (brack_group)
  (brack_group_argc)
  (brack_group_key_value)
  (brack_group_text)
  (brack_group_word)
] @block.outer

; `{`/`}` and `[`/`]` are single characters, so the group body is an exact offset.
([
  (curly_group)
  (curly_group_author_list)
  (curly_group_command_name)
  (curly_group_glob_pattern)
  (curly_group_impl)
  (curly_group_key_value)
  (curly_group_label)
  (curly_group_label_list)
  (curly_group_path)
  (curly_group_path_list)
  (curly_group_spec)
  (curly_group_text)
  (curly_group_text_list)
  (curly_group_uri)
  (curly_group_value)
  (curly_group_word)
  (brack_group)
  (brack_group_argc)
  (brack_group_key_value)
  (brack_group_text)
  (brack_group_word)
] @block.inner
  (#offset! @block.inner 0 1 0 -1))

; ---------------------------------------------------------------------------
; ITEM — one \item entry of a list
; ---------------------------------------------------------------------------
(enum_item) @statement.outer

(enum_item
  command: _
  .
  _+ @statement.inner)

; ---------------------------------------------------------------------------
; COMMENTS
; ---------------------------------------------------------------------------
[
  (line_comment)
  (block_comment)
  (comment_environment)
] @comment.outer
