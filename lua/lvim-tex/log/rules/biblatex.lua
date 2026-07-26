-- lvim-tex: log rules for the bibliography chain — biblatex, biber and classic bibtex.
-- Bibliography failures are the ones users most often mis-read as "my citations are broken": biber
-- reports a missing entry with its own vocabulary, in its own log, and the TeX run only shows the
-- downstream symptom. Naming the key (and saying WHICH tool complained) is the whole job here.
--
---@module "lvim-tex.log.rules.biblatex"

local S = vim.diagnostic.severity

---@type LvimTexLogRule[]
return {
    {
        id = "biber.missing-entry",
        pkg = "biber",
        -- `I didn't find a database entry for 'knuth1984'`
        match = "find a database entry for",
        severity = S.ERROR,
        extract = function(rec)
            local key = rec.text:match("entry for%s+'(.-)'") or rec.text:match('entry for%s+"(.-)"')
            return { message = ("biber: no bibliography entry for %s"):format(key or "?") }
        end,
    },
    {
        id = "biber.datasource-missing",
        pkg = "biber",
        match = "Data source.-not found",
        severity = S.ERROR,
        extract = function(rec)
            local src = rec.text:match("Data source%s+'?(.-)'?%s+not found")
            return { message = ("biber: bibliography file not found: %s"):format(src or "?") }
        end,
    },
    {
        id = "biber.invalid-field",
        pkg = "biber",
        match = "invalid in data model",
        severity = S.WARN,
    },
    {
        id = "biber.rerun",
        pkg = "biblatex",
        -- biblatex asks for a biber run explicitly; latexmk does it, so this is informational.
        match = "Please %(re%)run Biber",
        severity = S.INFO,
        extract = function()
            return { message = "biblatex: biber must run again (latexmk handles it)" }
        end,
    },
    {
        id = "biblatex.rerun-latex",
        pkg = "biblatex",
        match = "Please rerun LaTeX",
        severity = S.INFO,
    },
    {
        id = "bibtex.empty-entry",
        pkg = "bibtex",
        match = "^Empty%s+`",
        severity = S.WARN,
        extract = function(rec)
            local field = rec.text:match("^Empty%s+`(.-)'")
            local key = rec.text:match("in%s+(.+)$")
            return { message = ("bibtex: empty %s field in %s"):format(field or "?", key or "?") }
        end,
    },
    {
        id = "bibtex.repeated-entry",
        pkg = "bibtex",
        match = "Repeated entry",
        severity = S.WARN,
    },
}
