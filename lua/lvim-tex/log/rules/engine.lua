-- lvim-tex: log rules for failures that come from the ENGINE rather than from a package — TeX's own
-- fixed-size registers and capacities, and inputenc, which is where a byte in the source meets the
-- engine that has to read it.
--
-- These share one property that makes them worth rewriting: the engine states a FACT about its
-- internals and never the cause. "TeX capacity exceeded, sorry [input stack size=10000]" is what an
-- infinite macro recursion looks like. "No room for a new \write" is what loading one package too
-- many looks like. "Unicode character ✓ (U+2713)" is what pasting a glyph into a pdfLaTeX document
-- looks like — and the half of the sentence that would explain it ("not set up for use with LaTeX")
-- is on the next physical log line, which the parser cannot join to it, so without a rule the
-- diagnostic is a bare character name.
--
-- Not covered here: `Emergency stop.` and `Missing character: There is no X in font …`. The first
-- always follows the real error it aborted on and would only duplicate it; the second is not one of
-- the four shapes the parser classifies, so no rule can ever see it.
--
---@module "lvim-tex.log.rules.engine"

local S = vim.diagnostic.severity

---@type LvimTexLogRule[]
return {
    {
        id = "inputenc.unicode-not-set-up",
        pkg = "inputenc",
        match = "Unicode character%s+.-%(U%+%x+%)",
        severity = S.ERROR,
        extract = function(rec)
            local char, code = rec.text:match("Unicode character%s+(.-)%s*%((U%+%x+)%)")
            return {
                message = ("inputenc: %s %s has no pdfLaTeX definition — \\DeclareUnicodeCharacter it, or build with xelatex/lualatex"):format(
                    char or "?",
                    code or "?"
                ),
            }
        end,
    },
    {
        id = "inputenc.ignored-unicode-engine",
        pkg = "inputenc",
        -- xelatex/lualatex read UTF-8 natively, so \usepackage[utf8]{inputenc} does nothing and the
        -- line should go. Emitted while inputenc.sty itself is being read, so the file stack
        -- attributes it to that file under texmf: it surfaces in the project list, not inline in
        -- the user's preamble. Kept anyway because no other message reports the dead \usepackage.
        match = "inputenc package ignored with",
        severity = S.HINT,
        extract = function()
            return { message = "inputenc: ignored by this engine — remove \\usepackage[utf8]{inputenc}" }
        end,
    },
    {
        id = "engine.capacity-exceeded",
        pkg = "tex",
        -- `TeX capacity exceeded, sorry [input stack size=10000].` The bracket names WHICH fixed
        -- table filled up, which is the only part that distinguishes a runaway macro (input stack,
        -- grouping levels) from a genuinely enormous document (main memory, pool size).
        match = "^TeX capacity exceeded",
        severity = S.ERROR,
        extract = function(rec)
            local what, limit = rec.text:match("%[(.-)=(%d+)%]")
            return {
                message = ("TeX ran out of %s (limit %s) — usually an unterminated macro recursion"):format(
                    what or "an internal table",
                    limit or "?"
                ),
            }
        end,
    },
    {
        id = "engine.no-room-for-register",
        pkg = "tex",
        -- `No room for a new \write.` (also \read, \box, \dimen, \count, \toks). TeX has a fixed
        -- number of each; every package that allocates one brings the document closer to the wall,
        -- so the fix is never in the line the error points at.
        match = "^No room for a new",
        severity = S.ERROR,
        extract = function(rec)
            local kind = rec.text:match("a new%s+(\\%a+)")
            return {
                message = ("no %s registers left — too many packages are allocating them; load fewer"):format(
                    kind or "free"
                ),
            }
        end,
    },
    {
        id = "engine.no-output",
        pkg = "tex",
        -- `==> Fatal error occurred, no output PDF file produced!` The run stopped; the error that
        -- stopped it is already reported on its own line, so this only states the consequence —
        -- a HINT, not a second ERROR counted against the same defect.
        match = "Fatal error occurred, no output",
        severity = S.HINT,
        extract = function()
            return { message = "the run aborted — no PDF was produced" }
        end,
    },
}
