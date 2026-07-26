-- lvim-tex.imaps.data: the SHIPPED maths abbreviations — trigger → the LaTeX it becomes.
--
-- Data only, no logic, no requires. It is OUR OWN table, deliberately NOT derived from
-- `lvim-tex.conceal.data`: the two describe the same symbols from opposite ends. Conceal maps a
-- COMMAND to the glyph it renders as (`\alpha` → α) — a mechanical, complete, 800-entry table. An
-- imap maps a MNEMONIC a human chooses to type to a command (`a` → `\alpha`), and no rule can derive
-- "a" from "α": the inverse is not a function (which of ∈, ∩, ∪ gets `i`?), it is a design. So the
-- table is written, not generated — and the proof runner asserts every replacement here is a command
-- the conceal layer knows, so the two files can never drift apart.
--
-- THE ONE INVARIANT: no trigger may be a PREFIX of another trigger. These fire as you TYPE, with no
-- accept key, so the shorter of two would always expand first and the longer could never be reached.
-- That is why the greek letters own the single lowercase keys and everything else is built from the
-- three characters they leave free:
--
--   • `v` + letter — the `var` shapes (`vf` → `\varphi`), which is exactly what they are;
--   • `o` + symbol — the CIRCLED operators (`o+` → `\oplus`, `ox` → `\otimes`, `oo` → `\circ`);
--   • `-` + key    — the ARROW family (`->` → `\to`, `-R` → `\Rightarrow`), the shaft of the arrow
--                    being the mnemonic, plus `-+` → `\mp` (minus-plus, read literally).
--
-- Anything that takes an ARGUMENT is deliberately absent — `\frac`, `\sqrt`, `\sum_{}^{}` are worth
-- tabstops, so they live in the snippet collection (`snippets/tex.json`), not here. An imap is one
-- symbol, always two or three keystrokes, never a template.
--
-- The unassigned keys are free on purpose: `j`, `J`, `K`, `M`, `O`, the digits 1-5, 7, 9 and the
-- symbols `&`, `#`, `_`, `:`, `;`, `?` carry nothing, so `imaps.mappings` can claim them without
-- overriding anything shipped.
--
---@module "lvim-tex.imaps.data"

local M = {}

---@class LvimTexImapGroup
---@field name  string      the heading this group is listed under
---@field items string[][]  `{ trigger, replacement }` pairs, in display order

--- The shipped set, grouped for the listing window (`:LvimTex imaps`) and ordered as a reader wants
--- to see it, not alphabetically.
---@type LvimTexImapGroup[]
M.groups = {
    {
        name = "Greek",
        items = {
            { "a", "\\alpha" },
            { "b", "\\beta" },
            { "g", "\\gamma" },
            { "d", "\\delta" },
            { "e", "\\epsilon" },
            { "z", "\\zeta" },
            { "h", "\\eta" },
            { "q", "\\theta" },
            { "i", "\\iota" },
            { "k", "\\kappa" },
            { "l", "\\lambda" },
            { "m", "\\mu" },
            { "n", "\\nu" },
            { "x", "\\xi" },
            { "p", "\\pi" },
            { "r", "\\rho" },
            { "s", "\\sigma" },
            { "t", "\\tau" },
            { "u", "\\upsilon" },
            { "f", "\\phi" },
            { "c", "\\chi" },
            { "y", "\\psi" },
            { "w", "\\omega" },
        },
    },
    {
        name = "Greek (var shapes)",
        items = {
            { "ve", "\\varepsilon" },
            { "vq", "\\vartheta" },
            { "vp", "\\varpi" },
            { "vr", "\\varrho" },
            { "vs", "\\varsigma" },
            { "vf", "\\varphi" },
        },
    },
    {
        name = "Greek (capitals)",
        items = {
            { "G", "\\Gamma" },
            { "D", "\\Delta" },
            { "Q", "\\Theta" },
            { "L", "\\Lambda" },
            { "X", "\\Xi" },
            { "P", "\\Pi" },
            { "S", "\\Sigma" },
            { "U", "\\Upsilon" },
            { "F", "\\Phi" },
            { "Y", "\\Psi" },
            { "W", "\\Omega" },
        },
    },
    {
        name = "Sets and logic",
        items = {
            { "A", "\\forall" },
            { "E", "\\exists" },
            { "I", "\\in" },
            { "V", "\\nabla" },
            { "N", "\\mathbb{N}" },
            { "Z", "\\mathbb{Z}" },
            { "R", "\\mathbb{R}" },
            { "C", "\\mathbb{C}" },
            { "(", "\\subset" },
            { ")", "\\supset" },
            { "[", "\\subseteq" },
            { "]", "\\supseteq" },
            { "{", "\\cap" },
            { "}", "\\cup" },
            { "^", "\\wedge" },
            { "|", "\\vee" },
        },
    },
    {
        name = "Operators and relations",
        items = {
            { ".", "\\cdot" },
            { "*", "\\times" },
            { "/", "\\div" },
            { "+", "\\pm" },
            { "\\", "\\setminus" },
            { "=", "\\equiv" },
            { "<", "\\leq" },
            { ">", "\\geq" },
            { "!", "\\neq" },
            { "~", "\\sim" },
            { "%", "\\approx" },
            { "$", "\\propto" },
            { '"', "\\parallel" },
            { "'", "\\prime" },
            { ",", "\\dots" },
        },
    },
    {
        name = "Circled operators",
        items = {
            { "o+", "\\oplus" },
            { "o-", "\\ominus" },
            { "ox", "\\otimes" },
            { "o/", "\\oslash" },
            { "o.", "\\odot" },
            { "oo", "\\circ" },
            { "o*", "\\bullet" },
        },
    },
    {
        name = "Arrows",
        items = {
            { "->", "\\to" },
            { "-<", "\\gets" },
            { "-R", "\\Rightarrow" },
            { "-L", "\\Leftarrow" },
            { "-E", "\\Leftrightarrow" },
            { "-M", "\\mapsto" },
            { "-U", "\\uparrow" },
            { "-D", "\\downarrow" },
            { "-+", "\\mp" },
        },
    },
    {
        name = "Symbols",
        items = {
            { "0", "\\emptyset" },
            { "8", "\\infty" },
            { "6", "\\partial" },
            { "T", "\\top" },
            { "B", "\\bot" },
            { "H", "\\hbar" },
        },
    },
}

--- The shipped set as a flat `trigger → replacement` table (what the merge in `lvim-tex.imaps`
--- starts from). Built once from `M.groups`, so the groups stay the single source.
---@type table<string, string>
M.mappings = {}

--- The group each shipped trigger belongs to — the listing window shows it, and it is how a user
--- finds out which family a mapping came from.
---@type table<string, string>
M.group_of = {}

for _, group in ipairs(M.groups) do
    for _, item in ipairs(group.items) do
        M.mappings[item[1]] = item[2]
        M.group_of[item[1]] = group.name
    end
end

return M
