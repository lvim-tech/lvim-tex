-- lvim-tex: the log RULE TABLE — the growth mechanism behind per-package message fidelity.
--
-- The core parser (lvim-tex.log) recognises the four generic SHAPES a TeX log uses. Everything
-- beyond that — what a specific package's wording actually means, which line it really refers to,
-- and whether it deserves an error, a warning or a hint — is DATA, collected here. Adding coverage
-- for a package is adding a row, never editing the parser.
--
-- A rule is tried against every classified record, shipped rules first and the user's
-- `diagnostics.rules` last, so a user row can override a shipped verdict by matching the same text.
-- The FIRST match wins; `:LvimTex info` names the winning rule per entry, which is what makes a
-- wrong verdict debuggable instead of mysterious.
--
-- `match` is a Lua PATTERN (not a plain substring), so literal backslashes, brackets and dashes in a
-- TeX message must be escaped with `%`.
--
---@module "lvim-tex.log.rules"

---@class LvimTexLogRule
---@field id        string    Stable identifier, reported by `:LvimTex info` (e.g. "latex.undefined-ref")
---@field pkg?      string    The TeX package the rule belongs to, for documentation and health
---@field match     string|fun(rec: LvimTexRecord): boolean  Lua pattern against the record text, or a predicate
---@field severity? integer   A vim.diagnostic.severity value that replaces the shape's default
---@field extract?  fun(rec: LvimTexRecord): table|false|nil  Refine file/lnum/col/message; `false` DROPS the record

local graphics = require("lvim-tex.log.rules.graphics")
local tables = require("lvim-tex.log.rules.tables")
local listings = require("lvim-tex.log.rules.listings")
local refs = require("lvim-tex.log.rules.refs")
local engine = require("lvim-tex.log.rules.engine")
local latex = require("lvim-tex.log.rules.latex")
local hyperref = require("lvim-tex.log.rules.hyperref")
local biblatex = require("lvim-tex.log.rules.biblatex")
local babel = require("lvim-tex.log.rules.babel")
local fonts = require("lvim-tex.log.rules.fonts")
local layout = require("lvim-tex.log.rules.layout")

local M = {}

-- Order matters: the specific packages come BEFORE the core LaTeX rules, because a package warning
-- often also matches a generic core pattern (a hyperref bookmark complaint contains the word
-- "Warning" like everything else), and the more specific verdict is the useful one.
--
-- Two positions inside the list are load-bearing in the same way, and were established by running the
-- log corpus rather than by reasoning about it:
--   • `graphics` before `latex` — a driver's "File `x.png' not found: using draft setting" is a
--     graphics failure, not the kernel's generic missing-file error.
--   • `refs` before `biblatex` — natbib's "Empty `thebibliography' environment" otherwise matches
--     bibtex's empty-entry rule and is reported as "empty thebibliography field in ?".
---@type LvimTexLogRule[][]
local GROUPS = { graphics, tables, listings, refs, engine, hyperref, biblatex, babel, fonts, layout, latex }

---@type LvimTexLogRule[]?
local flat = nil

--- Every shipped rule, flattened once and cached.
---@return LvimTexLogRule[]
function M.all()
    if flat then
        return flat
    end
    flat = {}
    for _, group in ipairs(GROUPS) do
        for _, rule in ipairs(group) do
            flat[#flat + 1] = rule
        end
    end
    return flat
end

--- Rule ids per package, for health and the vimdoc's coverage table.
---@return table<string, string[]>
function M.by_package()
    local out = {}
    for _, rule in ipairs(M.all()) do
        local pkg = rule.pkg or "core"
        out[pkg] = out[pkg] or {}
        table.insert(out[pkg], rule.id)
    end
    return out
end

return M
