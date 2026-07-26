-- lvim-tex: log rules for the cross-referencing and citation-style layer — cleveref, varioref and
-- natbib. (The KEY-level failures — "Reference `x' undefined", "Citation `y' undefined" — belong to
-- the kernel and are already covered in `rules/latex.lua`; natbib phrases them identically, so they
-- fall through to it on purpose.)
--
-- What is left is the class of problem those kernel rules cannot express: the reference machinery
-- itself is misconfigured. cleveref must see hyperref, varioref and amsmath BEFORE it loads or it
-- cannot patch them — an ordering mistake in the preamble that produces an error pointing at
-- \begin{document}, nowhere near the two \usepackage lines that need swapping. natbib in author-year
-- mode against a numeric .bst silently degrades every citation in the document to numbers. And
-- varioref's page-boundary warning is the only message in a normal log that predicts a build which
-- never converges, because the reference text changes the pagination that determines the reference
-- text.
--
-- This group must sit BEFORE `biblatex` in the rule table: natbib's "Empty `thebibliography'
-- environment" would otherwise be claimed by the bibtex rule for empty FIELDS and reported as
-- "empty thebibliography field in ?".
--
---@module "lvim-tex.log.rules.refs"

local S = vim.diagnostic.severity

---@type LvimTexLogRule[]
return {
    {
        id = "cleveref.load-order",
        pkg = "cleveref",
        -- `Package cleveref Error: cleveref must be loaded after hyperref!` — one message per
        -- package it failed to patch, so a preamble can raise it two or three times in a row.
        match = "cleveref must be loaded after",
        severity = S.ERROR,
        extract = function(rec)
            local pkg = rec.text:match("loaded after%s+([%w@%-]+)")
            return {
                message = ("cleveref: move \\usepackage{cleveref} AFTER \\usepackage{%s}"):format(pkg or "it"),
            }
        end,
    },
    {
        id = "varioref.page-boundary",
        pkg = "varioref",
        -- `\vref or \vpageref at page boundary 1-2 (may loop)`. The reference sits exactly on a
        -- break, so its own text ("on the next page" vs "on page 2") changes the page it is on,
        -- which changes the text again: latexmk can rerun forever without settling.
        match = "at page boundary",
        severity = S.WARN,
        extract = function(rec)
            local pages = rec.text:match("page boundary%s+([%d%-]+)")
            return {
                message = ("varioref: a \\vref sits on the %s page break and may never settle — use \\ref/\\pageref here"):format(
                    pages or "?"
                ),
            }
        end,
    },
    {
        id = "varioref.unsupported-language",
        pkg = "varioref",
        -- varioref keeps compiling with its ENGLISH strings, so a French document quietly gets
        -- "on the following page" in the middle of its own prose.
        match = "Sorry, language%s+[`']",
        severity = S.WARN,
        extract = function(rec)
            local lang = rec.text:match("language%s+[`'](.-)'")
            return {
                message = ("varioref: no %s strings — the English wording is used for \\vref"):format(lang or "?"),
            }
        end,
    },
    {
        id = "natbib.not-author-year",
        pkg = "natbib",
        -- `Bibliography not compatible with author-year citations.` The .bbl was produced by a
        -- NUMERIC .bst (plain, unsrt, ieeetr …) while natbib was asked for author-year, so every
        -- \citet/\citep in the document falls back to a bare number.
        match = "not compatible with author%-year",
        severity = S.ERROR,
        extract = function()
            return {
                message = "natbib: the .bst is numeric but author-year citations were requested — use plainnat/abbrvnat, or drop the authoryear option",
            }
        end,
    },
    {
        id = "natbib.field-undefined",
        pkg = "natbib",
        -- The same root cause as above, seen per citation: `Author undefined for citation`key'` and
        -- its `Year` twin, both raised from natbib's one \NAT@test, so they are one rule. (natbib
        -- writes no space before the key, hence the `%s*`.) The citation prints a bold `(author?)`
        -- or `(year?)` in the PDF, which is what the reader will notice.
        match = "^%a+ undefined for citation",
        severity = S.WARN,
        extract = function(rec)
            local field = rec.text:match("^(%a+) undefined")
            local key = rec.text:match("citation%s*[`'](.-)'")
            return {
                message = ("natbib: no %s for %s — the .bst is not author-year, or the entry lacks the field"):format(
                    field and field:lower() or "author/year",
                    key or "?"
                ),
            }
        end,
    },
    {
        id = "natbib.empty-bibliography",
        pkg = "natbib",
        -- The .bbl exists but holds no \bibitem: bibtex ran and matched nothing, usually because
        -- the keys are misspelled or the .bib was never listed in \bibliography.
        match = "^Empty%s+[`']thebibliography'",
        severity = S.WARN,
        extract = function()
            return {
                message = "natbib: the bibliography is empty — bibtex found no entry for any cited key",
            }
        end,
    },
    {
        id = "natbib.multiple-citation",
        pkg = "natbib",
        -- Two entries share an author and a year, and the .bst gave neither a disambiguating
        -- letter, so the citation prints a literal question mark in the PDF.
        match = "^Multiple citation on page",
        severity = S.WARN,
        extract = function()
            return {
                message = "natbib: two entries share an author and year with no a/b suffix — the citation prints as `?'",
            }
        end,
    },
    {
        id = "natbib.cite-package-clash",
        pkg = "natbib",
        -- natbib repairs this itself by enabling its own option, so it is not a defect — but the
        -- \usepackage line should still go, and saying which option replaced it is the useful part.
        match = "package should not be used",
        severity = S.HINT,
        extract = function(rec)
            local pkg = rec.text:match("^The%s+[`'](.-)'")
            local option = pkg == "mcite" and "merge" or "sort"
            return {
                message = ("natbib: drop \\usepackage{%s} — use natbib's `%s' option instead"):format(
                    pkg or "cite",
                    option
                ),
            }
        end,
    },
    {
        id = "natbib.citations-changed",
        pkg = "natbib",
        -- natbib's own form of the kernel's rerun notice; latexmk iterates on its own.
        match = "^Citation%(s%) may have changed",
        severity = S.INFO,
        extract = function()
            return { message = "natbib: citations changed — a rerun is needed (latexmk handles it)" }
        end,
    },
}
