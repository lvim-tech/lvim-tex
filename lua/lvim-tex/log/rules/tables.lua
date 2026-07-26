-- lvim-tex: log rules for tabular material and list structure — array, longtable, tabularx,
-- multicol, enumitem, plus the two KERNEL alignment errors that in practice only ever fire inside a
-- table (`Extra alignment tab` and the `Misplaced …` family).
--
-- Tables split cleanly into two severities and the split is the whole point of this group:
--
--   * a broken COLUMN SPEC or a row with too many `&` is an ERROR — TeX drops cells on the floor,
--     and the engine's own wording ("Illegal pream-token", "Misplaced \noalign") tells a user
--     nothing about the `l`/`c`/`r` letter or the stray `\hline` that caused it;
--   * a WIDTH that has not settled yet is INFO — longtable measures a table on one run and applies
--     the result on the next, so "widths have changed" is the normal first pass, not a defect, and
--     latexmk reruns on its own.
--
-- Only tabularx's "too narrow" sits in between: the table really is wider than the space given to
-- it and will overhang the margin, which is a defect the author must resolve.
--
---@module "lvim-tex.log.rules.tables"

local S = vim.diagnostic.severity

---@type LvimTexLogRule[]
return {
    {
        id = "array.illegal-pream-token",
        pkg = "array",
        -- `Package array Error:  Illegal pream-token (Q): `c' used.` — the parenthesised token is
        -- the offending letter in the column spec; the quoted one is only what array substituted.
        match = "Illegal pream%-token",
        severity = S.ERROR,
        extract = function(rec)
            local token = rec.text:match("pream%-token%s+%((.-)%)")
            return {
                message = ("array: %s is not a column type — check the {…} column specification"):format(
                    token and ("`" .. token .. "'") or "that token"
                ),
            }
        end,
    },
    {
        id = "latex.extra-alignment-tab",
        pkg = "latex",
        -- `Extra alignment tab has been changed to \cr.` The row has more `&` than the column spec
        -- declares; TeX ends the row early and everything after it lands in the next one.
        match = "^Extra alignment tab",
        severity = S.ERROR,
        extract = function()
            return {
                message = "too many & in this row — the column specification declares fewer columns",
            }
        end,
    },
    {
        id = "latex.misplaced-alignment",
        pkg = "latex",
        -- Covers the whole family: `Misplaced \noalign` (an \hline where a row was expected),
        -- `Misplaced \omit`, `Misplaced \cr`, and `Misplaced alignment tab character &` (a bare `&`
        -- in ordinary text). One rule, because the fix is always "this belongs inside a table row".
        match = "^Misplaced ",
        severity = S.ERROR,
        extract = function(rec)
            local what = rec.text:match("^Misplaced%s+(\\%a+)") or rec.text:match("^Misplaced%s+(.-)%.")
            return {
                message = ("misplaced %s — an alignment command outside a table row (a stray \\hline or &)"):format(
                    what or "alignment command"
                ),
            }
        end,
    },
    {
        id = "longtable.column-widths-changed",
        pkg = "longtable",
        -- Measured on this run, applied on the next. Not a defect; latexmk iterates to a fixed
        -- point on its own, exactly like the kernel's own "Rerun to get cross-references right".
        match = "Column widths have changed",
        severity = S.INFO,
        extract = function()
            return { message = "longtable: column widths were measured — a rerun applies them (latexmk handles it)" }
        end,
    },
    {
        id = "longtable.table-widths-changed",
        pkg = "longtable",
        match = "Table widths have changed",
        severity = S.INFO,
        extract = function()
            return { message = "longtable: table widths were measured — a rerun applies them (latexmk handles it)" }
        end,
    },
    {
        id = "tabularx.columns-too-narrow",
        pkg = "tabularx",
        -- `Package tabularx Warning: X Columns too narrow (table too wide)` — the requested total
        -- width cannot hold the column separations, so the X columns collapse and the table
        -- overhangs. A real defect: widen the table or drop a column.
        match = "X Columns too narrow",
        severity = S.WARN,
        extract = function()
            return {
                message = "tabularx: the X columns do not fit the requested width — the table will overhang the margin",
            }
        end,
    },
    {
        id = "multicol.float-inside",
        pkg = "multicol",
        -- `Floats and marginpars not allowed inside `multicols' environment!` — the float is not
        -- typeset at all, so it silently disappears from the PDF.
        match = "Floats and marginpars not allowed",
        severity = S.WARN,
        extract = function()
            return {
                message = "multicol: a float or marginpar inside multicols is dropped — use \\begin{figure*} outside it",
            }
        end,
    },
    {
        id = "enumitem.unknown-key",
        pkg = "enumitem",
        -- `Package enumitem Error: nosuchopt undefined.` — the key name is the first word, and it
        -- is the only useful part of the sentence.
        match = "^Package enumitem Error:%s+.-%s+undefined",
        severity = S.ERROR,
        extract = function(rec)
            local key = rec.text:match("^Package enumitem Error:%s+(.-)%s+undefined")
            return { message = ("enumitem: unknown list option: %s"):format(key or "?") }
        end,
    },
}
