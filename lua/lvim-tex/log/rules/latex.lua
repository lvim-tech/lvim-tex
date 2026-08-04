-- lvim-tex: log rules for LaTeX's OWN messages (the kernel, not a package).
-- These are the messages every document can produce, so they carry the most weight: an undefined
-- reference or citation names the key that is missing, which is far more useful in the diagnostic
-- text than LaTeX's own sentence, and a "rerun" notice is an ACTION rather than a problem.
--
---@module "lvim-tex.log.rules.latex"

local S = vim.diagnostic.severity

local fn = vim.fn

--- Where the DOCUMENT asks for `package`, so a fatal error raised inside that package's own `.sty`
--- can be reported where the user can act on it.
---
--- A package error is raised while the `.sty` is being read, so the log's file stack points at a file
--- inside the TeX distribution — factually correct and completely useless: nobody fixes fontspec by
--- editing fontspec.sty. The line that CAUSED it is the `\usepackage` in the preamble.
---
--- Only the compiled file is searched, not the whole include graph: a preamble lives in the root
--- document (or in a file it inputs before `\begin{document}`, which is rare enough that the honest
--- fallback — the document's first line — is better than guessing). Returns nil when the target
--- cannot be read at all, and the caller then leaves the original attribution alone.
---@param target string?
---@param package string
---@return { file: string, lnum: integer }?
local function requested_at(target, package)
    if not target or fn.filereadable(target) ~= 1 then
        return nil
    end
    local ok, lines = pcall(fn.readfile, target)
    if not ok or type(lines) ~= "table" then
        return nil
    end
    local pattern = "\\%a*[Pp]ackage%s*%b[]?%s*{[^}]*" .. vim.pesc(package)
    for i, line in ipairs(lines) do
        -- `\usepackage{a,fontspec,b}` and `\RequirePackage[opt]{fontspec}` both count; a commented
        -- line does not.
        local code = line:match("^([^%%]*)") or ""
        if code:find(pattern) or code:find("\\%a*[Pp]ackage%s*{[^}]*" .. vim.pesc(package)) then
            return { file = target, lnum = i }
        end
    end
    return { file = target, lnum = 1 }
end

---@type LvimTexLogRule[]
return {
    {
        -- `Fatal Package fontspec Error: The fontspec package requires either XeTeX or LuaTeX.`
        -- Generic on purpose: every package raises its fatals through the same kernel machinery, so
        -- one rule re-points all of them at the line that loaded the package.
        id = "latex.fatal-package",
        pkg = "latex",
        match = "^Fatal Package%s+[%w@%-]+%s+Error",
        severity = S.ERROR,
        extract = function(rec)
            local package = rec.text:match("^Fatal Package%s+([%w@%-]+)%s+Error")
            local text = rec.text:match("Error:%s*(.+)$") or rec.text
            -- The continuation lines are glued on with the `(pkg)` marker still in them; drop those
            -- markers so the sentence reads as one.
            text = text:gsub("%(" .. vim.pesc(package or "") .. "%)%s*", " "):gsub("%s+", " ")
            local at = package and requested_at(rec.target, package) or nil
            return {
                file = at and at.file or nil,
                lnum = at and at.lnum or nil,
                message = ("%s: %s"):format(package or "package", vim.trim(text)),
            }
        end,
    },
    {
        -- Printed AFTER the error that actually stopped the run, at the same useless position. The
        -- parser drops it when a real error was reported and keeps it when nothing else was, so a
        -- silent failure still says something.
        id = "latex.emergency-stop",
        pkg = "latex",
        match = "^Emergency stop",
        severity = S.ERROR,
        extract = function(rec)
            local at = requested_at(rec.target, "")
            return {
                file = at and at.file or nil,
                lnum = at and 1 or nil,
                message = "the run stopped here — see the error above it",
            }
        end,
    },
    {
        id = "latex.undefined-ref",
        pkg = "latex",
        -- `Reference `fig:setup' on page 3 undefined on input line 42.` — note that LaTeX is not
        -- consistent about the opening quote (references use a backtick, citations a straight
        -- quote), so every rule that names a key accepts both.
        match = "^Reference%s+[`']",
        severity = S.WARN,
        extract = function(rec)
            local key = rec.text:match("^Reference%s+[`'](.-)'")
            return { message = ("undefined reference: %s"):format(key or "?") }
        end,
    },
    {
        id = "latex.undefined-cite",
        pkg = "latex",
        match = "^Citation%s+[`']",
        severity = S.WARN,
        extract = function(rec)
            local key = rec.text:match("^Citation%s+[`'](.-)'")
            return { message = ("undefined citation: %s"):format(key or "?") }
        end,
    },
    {
        id = "latex.multiply-defined",
        pkg = "latex",
        match = "^Label%s+[`'].-'%s+multiply defined",
        severity = S.WARN,
        extract = function(rec)
            local key = rec.text:match("^Label%s+[`'](.-)'")
            return { message = ("label defined more than once: %s"):format(key or "?") }
        end,
    },
    {
        id = "latex.rerun",
        pkg = "latex",
        -- Not a defect: latexmk reruns on its own, so this is informational only.
        match = "Rerun to get",
        severity = S.INFO,
        extract = function()
            return { message = "cross-references changed — a rerun is needed (latexmk handles it)" }
        end,
    },
    {
        id = "latex.undefined-refs-summary",
        pkg = "latex",
        -- The end-of-run summary duplicates entries already reported individually, but keeping it
        -- (as a hint on the root) is what tells the user the count they are looking for.
        match = "There were undefined ",
        severity = S.HINT,
    },
    {
        id = "latex.file-not-found",
        pkg = "latex",
        match = "File%s+[`'].-'%s+not found",
        severity = S.ERROR,
        extract = function(rec)
            local name = rec.text:match("File%s+[`'](.-)'")
            return { message = ("file not found: %s"):format(name or "?") }
        end,
    },
    {
        id = "latex.undefined-control-sequence",
        pkg = "latex",
        match = "^Undefined control sequence",
        severity = S.ERROR,
        extract = function(rec)
            -- The engine echoes the offending macro on the following log line, which the record
            -- carries verbatim when the log was not wrapped; keep whatever is there.
            local macro = rec.text:match("(\\[%a@]+)%s*$")
            return { message = macro and ("undefined control sequence: %s"):format(macro) or nil }
        end,
    },
    {
        id = "latex.missing-dollar",
        pkg = "latex",
        match = "^Missing %$ inserted",
        severity = S.ERROR,
        extract = function()
            return { message = "missing $ — maths used outside a maths environment" }
        end,
    },
    {
        id = "latex.missing-brace",
        pkg = "latex",
        match = "^Missing [%{%}] inserted",
        severity = S.ERROR,
    },
    {
        id = "latex.runaway-argument",
        pkg = "latex",
        match = "^Runaway argument",
        severity = S.ERROR,
        extract = function()
            return { message = "runaway argument — an unclosed group or a missing brace" }
        end,
    },
    {
        id = "latex.env-mismatch",
        pkg = "latex",
        -- `\begin{itemize} on input line 12 ended by \end{document}`
        match = "ended by%s+\\end",
        severity = S.ERROR,
    },
    {
        id = "latex.overfull-underfull",
        pkg = "latex",
        -- Boxes reach here only when diagnostics.boxes is on; the rule exists to give them a stable
        -- id and a shorter message than the engine's own sentence.
        match = function(rec)
            return rec.kind == "box"
        end,
        severity = S.HINT,
        extract = function(rec)
            local kind = rec.text:match("^(%a+)full")
            local amount = rec.text:match("%(([%d%.]+pt) too")
            local box = rec.text:match("\\([hv]box)")
            if kind and amount and box then
                return { message = ("%sfull \\%s (%s)"):format(kind:lower(), box, amount) }
            end
            return nil
        end,
    },
}
