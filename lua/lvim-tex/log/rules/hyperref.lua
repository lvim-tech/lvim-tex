-- lvim-tex: log rules for hyperref.
-- hyperref is the loudest package in a normal document: most of what it says is about PDF metadata
-- it silently worked around, so the value here is downgrading noise to a hint while keeping the two
-- messages that DO indicate a broken document (a bad bookmark nesting and a destination clash).
--
---@module "lvim-tex.log.rules.hyperref"

local S = vim.diagnostic.severity

---@type LvimTexLogRule[]
return {
    {
        id = "hyperref.pdfstring-token",
        pkg = "hyperref",
        -- Raised for maths or a macro inside a section title; hyperref strips it and carries on.
        match = "Token not allowed in a PDF string",
        severity = S.HINT,
        extract = function()
            return { message = "hyperref: a token was stripped from the PDF bookmark text" }
        end,
    },
    {
        id = "hyperref.bookmark-level",
        pkg = "hyperref",
        -- A section level was skipped (e.g. \section directly inside \part): the PDF outline nests
        -- wrongly, which is a real document defect.
        match = "between bookmark levels is greater than one",
        severity = S.WARN,
        extract = function()
            return { message = "hyperref: a heading level was skipped — the PDF outline will nest wrongly" }
        end,
    },
    {
        id = "hyperref.destination-duplicate",
        pkg = "hyperref",
        match = "destination with the same identifier",
        severity = S.WARN,
        extract = function(rec)
            local name = rec.text:match("identifier%s+%(name{(.-)}%)")
            return { message = ("hyperref: duplicate link destination%s"):format(name and (": " .. name) or "") }
        end,
    },
    {
        id = "hyperref.option-clash",
        pkg = "hyperref",
        match = "has already been used",
        severity = S.HINT,
    },
}
