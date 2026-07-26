-- lvim-tex.snippets: the shipped TeX snippet collection, handed to lvim-snippets (row E10).
--
-- lvim-tex owns no snippet engine and never will: expansion, tabstops, mirrors, the completion source
-- and the picker are lvim-snippets', and re-implementing any of it would mean two engines racing over
-- one buffer. What lvim-tex owns is the CONTENT — `snippets/tex.json`, a VS Code collection of the
-- document skeletons, environments and constructs a LaTeX document is made of.
--
-- Getting it loaded is the only real question. `config.paths` in lvim-snippets is the USER's list and
-- a clean array REPLACE on merge, so a plugin writing into it would silently drop the user's own
-- folders — which is why lvim-snippets grew `register_paths()` for this: a root scanned AFTER every
-- configured one, so a plugin's collection can never outrank yours, and the load order does not
-- matter. That seam is a feature of lvim-snippets, documented there; nothing here works around its
-- absence.
--
-- The split with the abbreviations (`lvim-tex.imaps`) is deliberate and is the reason both exist: an
-- imap is ONE symbol with no arguments, expanded silently as you type; a snippet is a CONSTRUCT with
-- holes to fill, chosen from a menu. `\alpha` is an imap, `\frac{a}{b}` is a snippet.
--
---@module "lvim-tex.snippets"

local config = require("lvim-tex.config")

local api = vim.api

local M = {}

--- The collection file's name inside the plugin (`snippets/tex.json` — the basename IS the filetype,
--- which is how lvim-snippets maps a loose file to a language).
local FILE = "snippets/tex.json"

--- A file that exists ONLY in this plugin, used to locate the plugin's own root on the runtimepath.
--- Searching for `snippets/tex.json` directly would find another plugin's collection of the same
--- name; this one cannot be anyone else's.
local MARKER = "lua/lvim-tex/snippets.lua"

---@type string?  the resolved collection directory, once found
local dir = nil

--- The directory holding the shipped collection, or nil when the plugin is not on the runtimepath in
--- a readable form (a packed/vendored install that dropped the data files).
---@return string?
function M.dir()
    if dir then
        return dir
    end
    local marker = api.nvim_get_runtime_file(MARKER, false)[1]
    if not marker then
        return nil
    end
    -- <root>/lua/lvim-tex/snippets.lua → <root>
    local root = vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(marker)))
    local path = vim.fs.joinpath(root, "snippets")
    if vim.fn.isdirectory(path) ~= 1 then
        return nil
    end
    dir = vim.fs.normalize(path)
    return dir
end

--- The collection file itself (health prints it; the proof reads it).
---@return string?
function M.file()
    local base = M.dir()
    if not base then
        return nil
    end
    local path = vim.fs.joinpath(base, vim.fs.basename(FILE))
    return vim.fn.filereadable(path) == 1 and vim.fs.normalize(path) or nil
end

--- Register the collection with lvim-snippets. Idempotent (registering the same root twice is a
--- no-op there), a no-op with `snippets.enabled = false`, and silent when lvim-snippets is absent —
--- `:checkhealth lvim-tex` is where that is reported, not a startup message.
---@return boolean registered, string? reason
function M.register()
    if not config.snippets.enabled then
        return false, "snippets.enabled = false"
    end
    local ok, snippets = pcall(require, "lvim-snippets")
    if not ok or type(snippets.register_paths) ~= "function" then
        return false, "lvim-snippets not installed (or too old for register_paths)"
    end
    local path = M.dir()
    if not path then
        return false, "the shipped collection was not found on the runtimepath"
    end
    snippets.register_paths(path)
    return true, nil
end

--- What health reports: where the collection is, whether it is registered, and how many `tex`
--- records the engine offers — that last number is the TOTAL (this collection plus whatever the user
--- has under their own roots), because a neutral record does not carry the file it came from.
---@return { dir: string?, registered: boolean, reason: string?, records: integer, prefixes: string[] }
function M.stats()
    local path = M.dir()
    local registered, reason = false, nil
    local ok, snippets = pcall(require, "lvim-snippets")
    if ok and type(snippets.paths) == "function" and path then
        for _, root in ipairs(snippets.paths()) do
            if vim.fs.normalize(vim.fn.expand(root)) == path then
                registered = true
            end
        end
    elseif not ok then
        reason = "lvim-snippets not installed"
    end
    local records, prefixes = 0, {}
    if ok and type(snippets.get) == "function" then
        for _, record in ipairs(snippets.get("tex")) do
            records = records + 1
            prefixes[#prefixes + 1] = record.prefix
        end
    end
    table.sort(prefixes)
    return { dir = path, registered = registered, reason = reason, records = records, prefixes = prefixes }
end

--- Called from the plugin's setup().
---@return nil
function M.setup()
    M.register()
end

return M
