;; extends

; lvim-tex: the one language-injection gap in the shipped latex bundle.
; Upstream already covers comments, `minted` (with a dynamic language from its
; `{…}` argument), pycode/sagesilent/sageblock -> python, luacode -> lua and
; asy/asydef -> c. Only `lstlisting` is missing, so only `lstlisting` is added here.
;
; The grammar gives no seam for the option group: a `listing_environment`'s `begin`
; has NO `options:` field — the external scanner swallows `[language=Python,…]` into
; the `code: (source_code)` leaf together with the code itself. The language therefore
; has to be recovered by pattern from that same leaf, which is why `source_code` is
; captured twice (once as the content, once as the language) and rewritten with
; `#gsub!` only for the language capture.
;
; The pattern is gated on `language=` actually being present: a plain
; `\begin{lstlisting}` has no language to inject and is left alone.
;
; The `listings` package treats its language names case-insensitively (`Python`,
; `python` and `PYTHON` are the same language) while tree-sitter parser names are
; always lower case. The query language has no case directive, so the extracted name
; is folded to lower case by a per-letter `#gsub!` chain — the directives apply in
; file order, each one seeing the previous one's result.
;
; Known limit of the same grammar gap: `@injection.content` is the whole
; `source_code` leaf, so the injected region starts with the `[…]` option text on the
; `\begin` row. `#offset!` cannot trim it — its column argument is a delta on the
; node's own start column, which varies with the environment's indentation, so any
; fixed value would cut real code off an indented listing.
((listing_environment
  code: (source_code) @injection.content @injection.language)
  (#lua-match? @injection.language "^%[[^%]]*[Ll]anguage%s*=")
  (#gsub! @injection.language "^%[[^%]]*[Ll]anguage%s*=%s*{?%s*([%w%+%-%._#]+).*" "%1")
  (#gsub! @injection.language "A" "a")
  (#gsub! @injection.language "B" "b")
  (#gsub! @injection.language "C" "c")
  (#gsub! @injection.language "D" "d")
  (#gsub! @injection.language "E" "e")
  (#gsub! @injection.language "F" "f")
  (#gsub! @injection.language "G" "g")
  (#gsub! @injection.language "H" "h")
  (#gsub! @injection.language "I" "i")
  (#gsub! @injection.language "J" "j")
  (#gsub! @injection.language "K" "k")
  (#gsub! @injection.language "L" "l")
  (#gsub! @injection.language "M" "m")
  (#gsub! @injection.language "N" "n")
  (#gsub! @injection.language "O" "o")
  (#gsub! @injection.language "P" "p")
  (#gsub! @injection.language "Q" "q")
  (#gsub! @injection.language "R" "r")
  (#gsub! @injection.language "S" "s")
  (#gsub! @injection.language "T" "t")
  (#gsub! @injection.language "U" "u")
  (#gsub! @injection.language "V" "v")
  (#gsub! @injection.language "W" "w")
  (#gsub! @injection.language "X" "x")
  (#gsub! @injection.language "Y" "y")
  (#gsub! @injection.language "Z" "z"))
