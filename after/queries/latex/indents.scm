; lvim-tex: LaTeX indentation, for the lvim-ts query-indent engine.
; The latex query bundle ships NO `indents.scm` (bibtex and typst do), so this file is
; entirely ours. It feeds `lvim-ts.core.indent`, which walks from the node at the target
; line UP to the root and consumes exactly these captures:
;
;   @indent.begin   an ancestor STARTING ABOVE the line  -> +1 level (once per start row)
;   @indent.end     a node STARTING ON the line          -> -1 level
;   @indent.branch  same as @indent.end, for `else`-like rows
;   @indent.dedent  same as @indent.end, unconditional
;   @indent.ignore  stop the walk here (the row resolves to column 0)
;   @indent.zero    force column 0
;   @indent.align   column-align to an open delimiter (needs indent.open_delimiter)
;
; Levels follow latexindent (the formatter lvim-lang uses for LaTeX), so a
; `<motion>=` and a `:LvimFormat` agree instead of fighting:
;   * every environment body indents one level  (`indentAfterEnvironment`)
;   * `document` and `comment` do NOT              (`noAdditionalIndent: document/comment`)
;   * an `\item` body indents one more level        (`indentAfterItems`)
;   * headings (\section …) do NOT indent their content (`afterHeading: 0`)
;   * verbatim / lstlisting / minted bodies are literal (`verbatimEnvironments`)

; ---------------------------------------------------------------------------
; ENVIRONMENTS
; ---------------------------------------------------------------------------
; \begin{x} … \end{x}: the body sits one level in; the \end row pulls back so it
; lines up with its \begin. `document` and `comment` are excluded — their bodies
; stay at the surrounding level, which is both the LaTeX convention and
; latexindent's `noAdditionalIndent` default.
((generic_environment
  (begin
    name: (curly_group_text
      (text) @_name))) @indent.begin
  (#not-any-of? @_name "document" "comment"))

; The specialised environment nodes. The verbatim-like ones are included so their
; `\end{…}` row still de-indents onto its `\begin{…}`; their BODY is neutralised by
; the @indent.ignore rule below, not by leaving the environment uncaptured.
[
  (math_environment)
  (listing_environment)
  (verbatim_environment)
  (minted_environment)
  (pycode_environment)
  (sagesilent_environment)
  (sageblock_environment)
  (luacode_environment)
  (asy_environment)
  (asydef_environment)
] @indent.begin

(end) @indent.end

; ---------------------------------------------------------------------------
; VERBATIM-LIKE BODIES — never re-indented
; ---------------------------------------------------------------------------
; A verbatim / lstlisting / minted body is literal text: it must not inherit the
; indent of the environments around it. @indent.ignore is the engine's only "stop
; computing here" lever, so these rows resolve to column 0 instead of drifting right
; with every enclosing environment. (A body with a working injection — minted, or an
; lstlisting with `language=` — never reaches this query at all: lvim-ts resolves the
; innermost injected language and indents by ITS grammar.)
(source_code) @indent.ignore

(verbatim_environment
  verbatim: (comment) @indent.ignore)

; ---------------------------------------------------------------------------
; LIST ITEMS
; ---------------------------------------------------------------------------
; An item's continuation rows indent one level past the `\item` row itself; the row
; that STARTS an item is not affected (its enum_item begins on that same row).
(enum_item) @indent.begin

; ---------------------------------------------------------------------------
; DISPLAY MATH AND \left … \right
; ---------------------------------------------------------------------------
(displayed_equation) @indent.begin

(displayed_equation
  "\\]" @indent.end)

(math_delimiter) @indent.begin

(math_delimiter
  right_command: _ @indent.end)

; ---------------------------------------------------------------------------
; BRACE AND BRACKET GROUPS
; ---------------------------------------------------------------------------
; A group spanning several rows indents its content; the row carrying the closer
; de-indents. Single-row groups are inert: @indent.begin only counts an ancestor that
; STARTS above the target row.
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
] @indent.begin

[
  "}"
  "]"
] @indent.end
