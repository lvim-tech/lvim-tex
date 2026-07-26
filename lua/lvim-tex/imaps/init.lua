-- lvim-tex.imaps: insert-mode MATHS abbreviations — a leader plus a mnemonic, expanded the moment it
-- is typed, and ONLY inside a maths zone (checklist row E9).
--
-- Two halves, and only one of them is ours.
--
-- The MECHANISM is lvim-snippets': a postfix rule is precisely "a pattern trigger that fires as you
-- type, with no menu and no accept key", which is what an imap is. Writing a second insert-mode
-- watcher here would mean two plugins racing on `TextChangedI` over the same buffer, so lvim-tex
-- registers rules instead — and the ONE thing the shared engine could not express, "fire here but not
-- there", was added to it as a proper feature (`when`, a predicate checked while matching), never
-- worked around on this side.
--
-- The DATA and the GATE are ours. `imaps/data.lua` is the mnemonic table; the gate is
-- `lvim-tex.zone.in_math`, the same call conceal (S4) makes — because "is this maths" must have ONE
-- answer in this plugin, and it is a parse-tree answer: a `@a` in prose, in a comment, in a verbatim
-- body or in the `\text{…}` of a formula stays the two characters that were typed.
--
-- Position matters: the gate is asked about the LEADER's column, not the cursor's — "expand where the
-- replacement will land" is the honest question, and the two differ at a formula's edge. The tree is
-- PARSED first (`ts.root`) rather than read: `vim.treesitter.get_node` returns the last parsed tree,
-- and the text that decides the answer was typed a keystroke ago.
--
---@module "lvim-tex.imaps"

local config = require("lvim-tex.config")
local data = require("lvim-tex.imaps.data")
local ts = require("lvim-tex.ts")
local zone = require("lvim-tex.zone")

local M = {}

--- Filetypes of the plugin's list that are BIBTEX, not LaTeX — an abbreviation is meaningless there
--- (the gate would refuse it anyway; this keeps the rules off those buffers entirely).
---@type table<string, boolean>
local BIBTEX_FILETYPES = { bib = true, bibtex = true }

---@type LvimSnippetsPostfixRule[]  the rules THIS plugin put into lvim-snippets, kept by identity so
--- a toggle removes exactly its own and never a user's or another plugin's
local installed = {}

--- The postfix module of lvim-snippets, or nil when it is not installed. Cross-plugin and optional:
--- lvim-tex works without it, with `:checkhealth` saying why the abbreviations do nothing.
---@return table?
local function postfix()
    local ok, mod = pcall(require, "lvim-snippets.postfix")
    return ok and mod or nil
end

--- The live rule list inside lvim-snippets' config, or nil when it is not installed.
---@return LvimSnippetsPostfixRule[]?
local function rule_list()
    local ok, cfg = pcall(require, "lvim-snippets.config")
    if not ok then
        return nil
    end
    cfg.postfix = cfg.postfix or { enabled = true, rules = {} }
    cfg.postfix.rules = cfg.postfix.rules or {}
    return cfg.postfix.rules
end

--- Escape a literal string for use INSIDE a Lua pattern (the trigger is typed text, not a pattern:
--- `.` must match a dot and nothing else).
---@param s string
---@return string
local function escape_pattern(s)
    return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

--- Escape a literal string for use as a SNIPPET BODY. The body is parsed as LSP snippet syntax, where
--- `$` starts a tabstop, `}` closes one and `\` escapes — so a LaTeX replacement has to say "literal"
--- about all three. `\alpha` would survive as it stands (the parser keeps an unknown escape), but
--- `\\` (a LaTeX line break) and `\,` (a thin space) would not, so every backslash is escaped rather
--- than the ones that happen to matter today.
---@param s string
---@return string
local function escape_body(s)
    return (s:gsub("([\\%$}])", "\\%1"))
end

--- The filetypes the rules are registered for: the plugin's list minus the BibTeX ones.
---@return string[]
function M.filetypes()
    local out = {}
    for _, ft in ipairs(config.filetypes or {}) do
        if not BIBTEX_FILETYPES[ft] then
            out[#out + 1] = ft
        end
    end
    return out
end

--- The EFFECTIVE abbreviation set: the shipped table, with `imaps.mappings` merged over it (a user
--- entry for a trigger replaces the shipped one, every other shipped trigger keeps its meaning) and
--- `imaps.disable` removed. A mapping whose value is `false` or the empty string is a disable too, so
--- either spelling works. The shipped data is never mutated.
---@return table<string, string>
function M.mappings()
    local out = {}
    for trigger, replacement in pairs(data.mappings) do
        out[trigger] = replacement
    end
    for trigger, replacement in pairs(config.imaps.mappings or {}) do
        if type(replacement) == "string" and replacement ~= "" then
            out[trigger] = replacement
        else
            out[trigger] = nil
        end
    end
    for _, trigger in ipairs(config.imaps.disable or {}) do
        out[trigger] = nil
    end
    return out
end

--- Triggers of the effective set that are a PREFIX of another trigger. Such a pair cannot both work:
--- with no accept key the shorter one fires the moment it is typed, so the longer is unreachable.
--- The shipped table is prefix-free (asserted by the proof); this is what tells a user who added
--- `{ ["s"] = "\\sum" }` beside the shipped `sq` why one of them never fires — health prints it.
---@param set table<string, string>?  default: the effective set
---@return string[][]  `{ shorter, longer }` pairs
function M.shadowed(set)
    set = set or M.mappings()
    local triggers = vim.tbl_keys(set)
    table.sort(triggers)
    local out = {}
    for _, short in ipairs(triggers) do
        for _, long in ipairs(triggers) do
            if short ~= long and #short < #long and long:sub(1, #short) == short then
                out[#out + 1] = { short, long }
            end
        end
    end
    return out
end

--- Is the position a rule matched at inside maths? The gate, and the only place it is asked.
---@param ctx LvimSnippetsPostfixCtx
---@return boolean
local function in_math(ctx)
    if not ts.is_latex(ctx.buf) then
        return false
    end
    -- Parse first: the trigger's last character was typed a keystroke ago, and `zone.in_math` reads
    -- whatever tree exists rather than building one.
    if not ts.root(ctx.buf) then
        return false
    end
    return zone.in_math(ctx.buf, ctx.row, ctx.from or ctx.col)
end

--- The postfix rules for the effective set — one per trigger, all sharing the gate.
---@return LvimSnippetsPostfixRule[]
function M.rules()
    local leader = config.imaps.leader or ""
    local fts = M.filetypes()
    local set = M.mappings()
    local triggers = vim.tbl_keys(set)
    table.sort(triggers)
    local out = {}
    for _, trigger in ipairs(triggers) do
        out[#out + 1] = {
            trigger = escape_pattern(leader .. trigger),
            body = escape_body(set[trigger]),
            desc = ("lvim-tex: %s%s → %s"):format(leader, trigger, set[trigger]),
            ft = fts,
            when = in_math,
        }
    end
    return out
end

--- Remove the rules this plugin installed (by identity — a user's rules and another plugin's are
--- untouched, and a rule the user removed by hand is simply not found).
---@return integer  how many were removed
function M.unregister()
    local rules = rule_list()
    if not rules or #installed == 0 then
        installed = {}
        return 0
    end
    local mine = {}
    for _, rule in ipairs(installed) do
        mine[rule] = true
    end
    local removed = 0
    for i = #rules, 1, -1 do
        if mine[rules[i]] then
            table.remove(rules, i)
            removed = removed + 1
        end
    end
    installed = {}
    return removed
end

--- Install the rules for the effective set, replacing whatever this plugin installed before (so
--- `setup()`, `:LvimTex reload` and a config change all converge on the same state instead of
--- stacking duplicates). A no-op with `imaps.enabled = false`, and with lvim-snippets absent.
---@return integer  how many rules are installed now
function M.register()
    M.unregister()
    local rules = rule_list()
    if not rules or not config.imaps.enabled then
        return 0
    end
    for _, rule in ipairs(M.rules()) do
        rules[#rules + 1] = rule
        installed[#installed + 1] = rule
    end
    -- The engine's watcher is installed by lvim-snippets' own setup() and only while its
    -- `postfix.enabled` is true. Attaching here as well would be a second owner of that autocmd; the
    -- health check reports the state instead, which is the honest fix for "nothing expands".
    return #installed
end

--- Re-read the config and converge (`:LvimTex reload`, a live `imaps.*` change).
---@return integer  how many rules are installed now
function M.refresh()
    return M.register()
end

--- Are the abbreviations on? Both halves have to be: ours registered, and the shared engine running.
---@return boolean enabled, boolean engine_on
function M.enabled()
    local ok, cfg = pcall(require, "lvim-snippets.config")
    local engine_on = ok and cfg.postfix ~= nil and cfg.postfix.enabled == true
    return config.imaps.enabled == true and #installed > 0, engine_on
end

--- Turn the abbreviations on or off for the session (`:LvimTex imaps toggle`). Writes the live
--- config, so everything that reads it — health, the listing window, a later reload — agrees.
---@param on boolean?  nil flips the current state
---@return boolean  the new state
function M.toggle(on)
    if on == nil then
        on = not config.imaps.enabled
    end
    config.imaps.enabled = on and true or false
    M.register()
    return config.imaps.enabled
end

--- What health reports: the counts, the engine's state and any shadowed trigger.
---@return { total: integer, installed: integer, enabled: boolean, engine: boolean, snippets: boolean, leader: string, shadowed: string[][] }
function M.stats()
    local set = M.mappings()
    local _, engine_on = M.enabled()
    return {
        total = vim.tbl_count(set),
        installed = #installed,
        enabled = config.imaps.enabled == true,
        engine = engine_on,
        snippets = postfix() ~= nil,
        leader = config.imaps.leader or "",
        shadowed = M.shadowed(set),
    }
end

--- The glyph conceal would draw for a replacement, so the listing reads as what it PRODUCES rather
--- than as a command name. Two shapes are looked up: a bare command (`\alpha` → α) and a maths
--- alphabet with a single letter (`\mathbb{N}` → ℕ), which conceal keeps as a letter table.
---@param replacement string
---@return string?
local function glyph_of(replacement)
    local conceal_data = require("lvim-tex.conceal.data")
    local glyph = conceal_data.math_symbols[replacement]
    if glyph then
        return glyph
    end
    local cmd, letter = replacement:match("^(\\%a+){(%a)}$")
    local letters = cmd and conceal_data.styles[cmd]
    return type(letters) == "table" and letters[letter] or nil
end

--- The listing ROWS — `{ keystrokes, "replacement  glyph   group" }` in the shipped grouping order,
--- with anything the user added last (so a custom entry is easy to spot instead of being scattered
--- through the greek). Separate from the window so the content is assertable without opening one.
---@return string[][]
function M.items()
    local leader = config.imaps.leader or ""
    local set = M.mappings()
    local items, seen = {}, {}
    local function row(trigger, group)
        local replacement = set[trigger]
        if not replacement or seen[trigger] then
            return
        end
        seen[trigger] = true
        local glyph = glyph_of(replacement)
        items[#items + 1] = {
            leader .. trigger,
            ("%s%s   %s"):format(replacement, glyph and ("  " .. glyph) or "", group),
        }
    end
    for _, group in ipairs(data.groups) do
        for _, item in ipairs(group.items) do
            row(item[1], group.name)
        end
    end
    local extra = {}
    for trigger in pairs(set) do
        if not seen[trigger] then
            extra[#extra + 1] = trigger
        end
    end
    table.sort(extra)
    for _, trigger in ipairs(extra) do
        row(trigger, "Custom")
    end
    return items
end

--- The listing window: every effective abbreviation, grouped, through the canonical help window —
--- a KEY column (the keystrokes, leader included) and a description column (the LaTeX it becomes,
--- followed by the glyph conceal would draw for it).
---
--- The footer carries the toggle, so the one window both ANSWERS "what can I type" and switches the
--- feature — which is what `:LvimTex imaps` is for.
---@return nil
function M.list()
    local leader = config.imaps.leader or ""
    local items = M.items()
    local on = config.imaps.enabled == true
    -- `lvim-ui` is required HERE, not hoisted: this module REGISTERS the abbreviations from `setup()`,
    -- and a hoisted UI require would make the whole plugin unloadable without the UI layer just to
    -- install a few postfix rules. The listing window is the only part that needs it.
    local ui = require("lvim-ui")
    ui.help({
        title = ("%s Maths abbreviations — %s (leader %q)"):format(config.icons.math, on and "on" or "off", leader),
        items = items,
        close_keys = { "q", "<Esc>" },
        footer = {
            bars = {
                {
                    align = "center",
                    items = {
                        {
                            key = "t",
                            name = on and "disable" or "enable",
                            run = function(st)
                                st.close()
                                M.toggle()
                            end,
                        },
                        {
                            key = "q",
                            name = "close",
                            run = function(st)
                                st.close()
                            end,
                        },
                    },
                },
            },
        },
    })
end

--- Register the abbreviations at plugin setup. Nothing is attached to a buffer and no autocmd is
--- created: the rules live in lvim-snippets, gated per position by `when` and per buffer by `ft`.
---@return nil
function M.setup()
    M.register()
end

return M
