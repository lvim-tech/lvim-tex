-- lvim-tex: log rules for font selection — NFSS (the kernel's font machinery), fontspec, fontenc.
-- Font messages are the classic false alarm: "font shape undefined" is reported per USE, so one
-- missing bold-italic can fill the diagnostics list with dozens of identical warnings, while a
-- fontspec "cannot find font" genuinely stops the run.
--
---@module "lvim-tex.log.rules.fonts"

local S = vim.diagnostic.severity

---@type LvimTexLogRule[]
return {
    {
        id = "fontspec.font-not-found",
        pkg = "fontspec",
        match = "annot find font",
        severity = S.ERROR,
        extract = function(rec)
            local name = rec.text:match("font%s+(.-)[,%.]") or rec.text:match('font%s+"(.-)"')
            return { message = ("fontspec: font not found: %s"):format(name and vim.trim(name) or "?") }
        end,
    },
    {
        id = "nfss.shape-undefined",
        pkg = "latex",
        match = "Font shape.-undefined",
        severity = S.HINT,
        extract = function(rec)
            local shape = rec.text:match("Font shape%s+`(.-)'")
            local used = rec.text:match("using%s+`(.-)'")
            return {
                message = ("font shape %s unavailable%s"):format(shape or "?", used and (" — using " .. used) or ""),
            }
        end,
    },
    {
        id = "nfss.size-substituted",
        pkg = "latex",
        match = "Size substitutions with differences",
        severity = S.HINT,
    },
    {
        id = "nfss.shapes-summary",
        pkg = "latex",
        -- The end-of-run summary of the per-use warnings above: pure duplication, and unlike the
        -- reference summary it names nothing actionable, so it is dropped outright.
        match = "Some font shapes were not available",
        extract = function()
            return false
        end,
    },
    {
        id = "fontenc.encoding-missing",
        pkg = "fontenc",
        match = "Encoding.-has changed",
        severity = S.WARN,
    },
}
