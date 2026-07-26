-- lvim-tex: log rules for code listings — listings and minted.
--
-- minted is the reason this group exists. It shells out to Pygments, so when the document is built
-- WITHOUT `-shell-escape` it does not say "shell escape is off": it says the highlighting style is
-- missing, or that it "cannot highlight code (minted executable is unavailable or disabled)", or —
-- in the v2 series — it names the flag but only after two unrelated errors have already scrolled
-- past. Users read those as a broken installation and reinstall Pygments. Every one of these rules
-- therefore rewrites the message to the ONE fix that actually applies: build with `-shell-escape`.
--
-- listings needs no shell at all, and its failures are plain name lookups — an unknown `language=`
-- or `style=`, or a missing `\lstinputlisting` file. It reports each twice (a vague "couldn't load"
-- followed by a precise "X undefined"); both are kept, because the vague one is what fires when a
-- future version renames the precise one, and the parser never drops a record silently.
--
-- Deliberately NOT covered: `Package shellesc Warning: Shell escape disabled on input line N`. It
-- names the true root cause, but its advice is exactly what the minted rules below already say —
-- and it is emitted while the requesting package's own `.sty` is being read, so the file stack
-- attributes it to a read-only file under texmf instead of a line the user can act on. Same fix,
-- worse placement, so it is left to fall through as a generic record.
--
---@module "lvim-tex.log.rules.listings"

local S = vim.diagnostic.severity

-- The single sentence every minted-without-shell-escape failure should end in.
local SHELL_ESCAPE = "compile with -shell-escape (and Pygments installed)"

---@type LvimTexLogRule[]
return {
    {
        id = "listings.load-failed",
        pkg = "listings",
        -- `Package Listings Error: Couldn't load requested language.` (or `… style.`) — the vague
        -- half of the pair; the precise "X undefined" record follows it on the same input line.
        match = "Couldn't load requested",
        severity = S.ERROR,
        extract = function(rec)
            local what = rec.text:match("requested%s+(%a+)")
            return { message = ("listings: could not load the requested %s"):format(what or "definition") }
        end,
    },
    {
        id = "listings.language-undefined",
        pkg = "listings",
        -- listings lowercases the name before complaining, so the text here rarely matches what the
        -- user typed — quoting it back is still the fastest way to spot the typo.
        match = "^Package Listings Error:%s+language%s+.-%s+undefined",
        severity = S.ERROR,
        extract = function(rec)
            local lang = rec.text:match("language%s+(%S+)%s+undefined")
            return {
                message = ("listings: unknown language: %s — see \\lstlistoflanguages for the supported set"):format(
                    lang or "?"
                ),
            }
        end,
    },
    {
        id = "listings.style-undefined",
        pkg = "listings",
        match = "^Package Listings Error:%s+style%s+.-%s+undefined",
        severity = S.ERROR,
        extract = function(rec)
            local style = rec.text:match("style%s+(%S+)%s+undefined")
            return {
                message = ("listings: unknown style: %s — define it with \\lstdefinestyle first"):format(
                    style or "?"
                ),
            }
        end,
    },
    {
        id = "listings.file-not-found",
        pkg = "listings",
        -- `File `snippets/demo(.py)' not found.` — listings prints the extension in parentheses to
        -- show it was appended, which reads like part of the name. Undo that before reporting it,
        -- otherwise the path in the diagnostic cannot be copied into a shell.
        match = "^Package Listings Error:%s+File%s+[`']",
        severity = S.ERROR,
        extract = function(rec)
            local name = rec.text:match("File%s+[`'](.-)'")
            if name then
                name = name:gsub("%((%.[%w]+)%)$", "%1")
            end
            return { message = ("listings: file not found: %s"):format(name or "?") }
        end,
    },
    {
        id = "minted.shell-escape",
        pkg = "minted",
        -- minted v2's own wording. It already names the flag, so the rewrite only shortens it —
        -- the value is the stable id and the ERROR severity shared with the rules below.
        match = "invoke LaTeX with the %-shell%-escape flag",
        severity = S.ERROR,
        extract = function()
            return { message = ("minted: shell escape is off — %s"):format(SHELL_ESCAPE) }
        end,
    },
    {
        id = "minted.executable-unavailable",
        pkg = "minted",
        -- minted v3's wording, and the confusing one: it appears as "Missing definition for
        -- highlighting style" and "Cannot highlight code", both of which read like a style problem.
        -- Both carry this same parenthetical, so one rule catches the pair.
        match = "minted executable is unavailable or disabled",
        severity = S.ERROR,
        extract = function()
            return { message = ("minted: could not run the minted/Pygments helper — %s"):format(SHELL_ESCAPE) }
        end,
    },
    {
        id = "minted.pygments-missing",
        pkg = "minted",
        -- Distinct from the flag being absent: the shell WAS reachable and `pygmentize` was not.
        match = "You must have%s+[`']pygmentize'%s+installed",
        severity = S.ERROR,
        extract = function()
            return { message = "minted: pygmentize is not on PATH — install Pygments (pip install Pygments)" }
        end,
    },
    {
        id = "minted.style-not-found",
        pkg = "minted",
        match = "Cannot find Pygments style",
        severity = S.ERROR,
        extract = function(rec)
            local style = rec.text:match("Pygments style%s+([%w%-_]+)")
            return {
                message = ("minted: Pygments style %s is unavailable — %s"):format(style or "?", SHELL_ESCAPE),
            }
        end,
    },
    {
        id = "minted.missing-output",
        pkg = "minted",
        -- The downstream symptom of every failure above: the highlighted fragment was never
        -- written, so \inputminted has nothing to read.
        match = "Missing Pygments output",
        severity = S.ERROR,
        extract = function()
            return { message = ("minted: no highlighted output was produced — %s"):format(SHELL_ESCAPE) }
        end,
    },
}
