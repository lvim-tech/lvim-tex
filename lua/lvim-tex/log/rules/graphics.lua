-- lvim-tex: log rules for graphics inclusion and colour — graphics/graphicx, the driver `.def`
-- files (pdftex.def, luatex.def, xetex.def, dvips.def) and xcolor.
--
-- Every one of these is fatal to the PAGE, not just to the run: a missing or unreadable image is
-- silently replaced by a draft box, an unknown extension stops \includegraphics dead, and an
-- undefined colour makes the engine abort mid-paragraph. So the severity is uniformly ERROR — the
-- work here is naming the OFFENDING FILE OR COLOUR, because the engine buries it in a sentence and
-- the driver packages phrase the same failure three different ways.
--
-- The driver's own "File `x.png' not found: using draft setting." also matches the kernel's generic
-- `latex.file-not-found`, which is why this group must sit BEFORE `latex` in the rule table: the
-- driver message is the one that explains what the reader will actually see in the PDF.
--
---@module "lvim-tex.log.rules.graphics"

local S = vim.diagnostic.severity

---@type LvimTexLogRule[]
return {
    {
        id = "graphics.image-not-found",
        pkg = "graphicx",
        -- `Package pdftex.def Error: File `fig/plot.png' not found: using draft setting.` — the
        -- driver name varies with the engine (pdftex/luatex/xetex/dvips.def), so it is a wildcard.
        match = "^Package%s+[%w%-]+%.def%s+Error:%s+File%s+[`']",
        severity = S.ERROR,
        extract = function(rec)
            local name = rec.text:match("File%s+[`'](.-)'")
            return {
                message = ("graphics: image not found: %s — an empty draft box is typeset instead"):format(
                    name or "?"
                ),
            }
        end,
    },
    {
        id = "graphics.unknown-extension",
        pkg = "graphicx",
        -- `LaTeX Error: Unknown graphics extension: .xyz.` — the file EXISTS, graphicx just has no
        -- rule for its suffix, so the fix is a converted file or a \DeclareGraphicsRule.
        match = "Unknown graphics extension",
        severity = S.ERROR,
        extract = function(rec)
            local ext = rec.text:match("extension:%s*(%.[%w]+)")
            return {
                message = ("graphics: no rule for the %s extension — convert the image or add \\DeclareGraphicsRule"):format(
                    ext or "?"
                ),
            }
        end,
    },
    {
        id = "graphics.no-bounding-box",
        pkg = "graphicx",
        -- `Cannot determine size of graphic in nobb.eps (no BoundingBox).` Classic when an EPS is
        -- fed to a driver that cannot measure it, or when the file is not really an EPS at all.
        match = "Cannot determine size of graphic",
        severity = S.ERROR,
        extract = function(rec)
            local name = rec.text:match("graphic in%s+(.-)%s+%(")
            return {
                message = ("graphics: %s carries no BoundingBox — give \\includegraphics an explicit width/height, or use a PDF"):format(
                    name or "the image"
                ),
            }
        end,
    },
    {
        id = "graphics.image-read-failed",
        pkg = "graphicx",
        -- `!pdfTeX error: pdflatex (file ./junk.jpg): reading JPEG image failed (no JPEG header
        -- found)`. This is the ENGINE refusing the bytes, so the file is corrupt or misnamed — a
        -- different failure from "not found", and the one users misdiagnose most.
        match = "reading %a+ image failed",
        severity = S.ERROR,
        extract = function(rec)
            local name = rec.text:match("%(file%s+(.-)%)")
            local fmt = rec.text:match("reading (%a+) image failed")
            return {
                message = ("graphics: %s is not a readable %s file — it is corrupt or has the wrong extension"):format(
                    name or "the image",
                    fmt or "image"
                ),
            }
        end,
    },
    {
        id = "xcolor.undefined-color",
        pkg = "xcolor",
        -- `Package xcolor Error: Undefined color `nosuchcolour'.` Almost always a typo, or a name
        -- from a colour set (dvipsnames/svgnames) that was never requested as a package option.
        match = "Undefined color%s+[`']",
        severity = S.ERROR,
        extract = function(rec)
            local name = rec.text:match("Undefined color%s+[`'](.-)'")
            return {
                message = ("xcolor: undefined colour: %s — \\definecolor it, or load the set it comes from"):format(
                    name or "?"
                ),
            }
        end,
    },
    {
        id = "xcolor.undefined-color-model",
        pkg = "xcolor",
        -- A separate message from the one above, and a separate mistake: the MODEL argument of
        -- \definecolor (rgb/RGB/HTML/cmyk/gray) is wrong, not the colour name.
        match = "Undefined color model",
        severity = S.ERROR,
        extract = function(rec)
            local model = rec.text:match("model%s+[`'](.-)'")
            return {
                message = ("xcolor: unknown colour model %s — expected one of rgb, RGB, HTML, cmyk, gray"):format(
                    model or "?"
                ),
            }
        end,
    },
}
