-- lvim-tex: log rules for babel / polyglossia (language selection and hyphenation).
-- A wrong language name is fatal to the run, while a missing hyphenation pattern only degrades line
-- breaking — the same "Warning:" shape carries both, so splitting them by severity is the point.
--
---@module "lvim-tex.log.rules.babel"

local S = vim.diagnostic.severity

---@type LvimTexLogRule[]
return {
    {
        id = "babel.unknown-language",
        pkg = "babel",
        match = "Unknown option.-language",
        severity = S.ERROR,
    },
    {
        id = "babel.language-not-loaded",
        pkg = "babel",
        match = "You haven't loaded the option",
        severity = S.ERROR,
        extract = function(rec)
            local lang = rec.text:match("option%s+`(.-)'")
            return { message = ("babel: language not loaded: %s"):format(lang or "?") }
        end,
    },
    {
        id = "babel.no-hyphenation",
        pkg = "babel",
        match = "No hyphenation patterns were preloaded",
        severity = S.HINT,
        extract = function(rec)
            local lang = rec.text:match("language%s+`(.-)'")
            return {
                message = ("babel: no hyphenation patterns for %s — line breaking will suffer"):format(lang or "?"),
            }
        end,
    },
    {
        id = "polyglossia.unknown-language",
        pkg = "polyglossia",
        match = "Unknown language",
        severity = S.ERROR,
    },
}
