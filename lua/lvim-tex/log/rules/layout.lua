-- lvim-tex: log rules for the layout/typography packages — geometry, microtype, pgf/tikz, amsmath,
-- caption, float. These share a trait: they report things the author usually cannot fix from the
-- line the message points at (a moved marginpar, an unpatchable footnote hook), so the severity is
-- what matters most — an unknown pgfkeys key is a genuine error, a shifted marginpar is a hint.
--
---@module "lvim-tex.log.rules.layout"

local S = vim.diagnostic.severity

---@type LvimTexLogRule[]
return {
    {
        id = "pgf.unknown-key",
        pkg = "pgf",
        -- `Sorry, I do not know the key '/tikz/foo', to which you passed 'bar'`
        match = "I do not know the key",
        severity = S.ERROR,
        extract = function(rec)
            local key = rec.text:match("key%s+'(.-)'")
            return { message = ("tikz/pgf: unknown key %s"):format(key or "?") }
        end,
    },
    {
        id = "pgfplots.compat",
        pkg = "pgfplots",
        match = "running in backwards compatibility mode",
        severity = S.HINT,
    },
    {
        id = "geometry.overspecification",
        pkg = "geometry",
        match = "Over%-specification in",
        severity = S.WARN,
        extract = function(rec)
            local dir = rec.text:match("in%s+`(.-)'")
            return { message = ("geometry: over-specified %s margins — one value was ignored"):format(dir or "?") }
        end,
    },
    {
        id = "microtype.unknown-list",
        pkg = "microtype",
        match = "I cannot find a.-list",
        severity = S.HINT,
    },
    {
        id = "microtype.patch-failed",
        pkg = "microtype",
        -- A known, harmless clash with packages that redefine the same internal hook. There is no
        -- author-side fix and no visible effect, so it is dropped rather than downgraded.
        match = "Unable to apply patch",
        extract = function()
            return false
        end,
    },
    {
        id = "amsmath.foreign-command",
        pkg = "amsmath",
        match = "Foreign command",
        severity = S.WARN,
        extract = function(rec)
            local cmd = rec.text:match("command%s+(\\%a+)")
            return { message = ("amsmath: %s is a plain-TeX command — use \\frac"):format(cmd or "\\over") }
        end,
    },
    {
        id = "latex.marginpar-moved",
        pkg = "latex",
        match = "Marginpar on page",
        severity = S.HINT,
    },
    {
        id = "float.h-changed",
        pkg = "float",
        match = "`h' float specifier changed to",
        severity = S.HINT,
    },
    {
        id = "caption.unsupported",
        pkg = "caption",
        match = "Unsupported document class",
        severity = S.WARN,
    },
}
