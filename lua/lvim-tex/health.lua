-- lvim-tex: :checkhealth lvim-tex.
--
-- A LaTeX setup fails in places the editor cannot show: a missing engine, a grammar that was never
-- installed, a `% !TEX program` directive naming an engine this backend cannot select, or a project
-- whose root resolves to the wrong file. Each check therefore reports the ANSWER, not just a status —
-- what is missing and the exact way to get it.
--
-- Read-only: nothing here mutates config or state.
--
---@module "lvim-tex.health"

local config = require("lvim-tex.config")
local root_mod = require("lvim-tex.root")
local rules = require("lvim-tex.log.rules")
local viewer = require("lvim-tex.viewer")
local synctex = require("lvim-tex.synctex")

local api = vim.api
local fn = vim.fn

local M = {}

-- Grammars lvim-tex reads. Both come from the fetched parser registry, so the fix is the same line.
---@type string[]
local GRAMMARS = { "latex", "bibtex" }

--- Report the active builder and whether its binary exists.
---@param health table
---@return nil
local function check_builder(health)
    local name = config.builder
    local spec = config.builders[name]
    if not spec then
        health.error(("config.builder = %q has no entry in config.builders"):format(name))
        return
    end
    local ok, mod = pcall(require, "lvim-tex.build." .. name)
    if not ok or type(mod) ~= "table" then
        health.warn(("builder %q is configured but not implemented in this version"):format(name))
        return
    end
    local available, detail = mod.available()
    if available then
        health.ok(("builder %s (%s)"):format(name, spec.bin))
    else
        health.error(detail or ("builder %s is unavailable"):format(name))
    end
end

--- Report the treesitter grammars, with the install line when one is missing.
---@param health table
---@return nil
local function check_grammars(health)
    for _, lang in ipairs(GRAMMARS) do
        if #api.nvim_get_runtime_file("parser/" .. lang .. ".so", false) > 0 then
            health.ok(("grammar %s installed"):format(lang))
        else
            health.warn(
                ("grammar %s is missing — the include graph, the TOC and the editing operators need it"):format(lang),
                { ('add it to lvim-ts\'s ensure_installed: { "%s" }'):format(lang) }
            )
        end
    end
end

--- Report the LSP side, which lvim-tex does NOT configure: texlab belongs to lvim-lang's latex
--- provider, and completion/definition/formatting all come from there.
---@param health table
---@return nil
local function check_lsp(health)
    local ok, lang = pcall(require, "lvim-lang")
    if not ok or type(lang) ~= "table" then
        health.warn("lvim-lang is not available — texlab (completion, references, formatting) will not attach", {
            "install lvim-lang; its latex provider owns the LSP wiring",
        })
        return
    end
    if fn.executable("texlab") == 1 then
        health.ok("texlab found (wired by lvim-lang's latex provider)")
    else
        health.warn("texlab is not on PATH — cite/label/command completion will be missing", {
            "install it through lvim-lang / lvim-pkg (mason package: texlab)",
        })
    end
end

--- The TeX buffer this health report should describe. It is deliberately NOT the current buffer:
--- `:checkhealth` opens a buffer of its own, so by the time these checks run the user's document is
--- the ALTERNATE buffer (or merely one of the loaded ones). Looking at the current buffer would make
--- the project section permanently report "open a TeX buffer".
---@return integer?
local function tex_buffer()
    local function is_tex(buf)
        return buf
            and buf > 0
            and api.nvim_buf_is_loaded(buf)
            and vim.tbl_contains(config.filetypes, vim.bo[buf].filetype)
    end
    local alternate = fn.bufnr("#")
    if is_tex(alternate) then
        return alternate
    end
    for _, win in ipairs(api.nvim_list_wins()) do
        local buf = api.nvim_win_get_buf(win)
        if is_tex(buf) then
            return buf
        end
    end
    for _, buf in ipairs(api.nvim_list_bufs()) do
        if is_tex(buf) then
            return buf
        end
    end
    return nil
end

--- Report the project a TeX buffer belongs to: the resolved root, the compile target, the out-dir,
--- and any `% !TEX` directive in play. A wrong root is the single most confusing failure in a
--- multi-file document, so it is shown rather than inferred.
---@param health table
---@return nil
local function check_project(health)
    local buf = tex_buffer()
    if not buf then
        health.info("open a TeX buffer to see the project report here")
        return
    end
    health.info(("reporting on %s"):format(fn.fnamemodify(api.nvim_buf_get_name(buf), ":~")))
    local root = root_mod.of(buf)
    if not root then
        health.warn("this buffer has no file on disk, so no project could be resolved")
        return
    end
    health.info(("root: %s"):format(root))
    local magic = root_mod.magic(api.nvim_buf_get_name(buf))
    if magic.root then
        health.info(("magic root directive: %s"):format(magic.root))
    end
    if magic.program then
        local engine = root_mod.engine(root)
        local builder = root_mod.program(root)
        if engine then
            health.info(("magic program directive: %s (passed to %s as an engine flag)"):format(engine, config.builder))
        elseif builder then
            health.info(("magic program directive selects the %s builder"):format(builder))
        else
            health.warn(("magic program directive %q is neither a known engine nor a builder"):format(magic.program))
        end
    end
    local out_dir = root_mod.out_dir(root)
    health.info(("out dir: %s%s"):format(out_dir, vim.uv.fs_stat(out_dir) and "" or " (not created yet)"))
end

--- Report the log-rule coverage, so growing it is visible.
---@param health table
---@return nil
local function check_rules(health)
    local by_package = rules.by_package()
    local packages = vim.tbl_keys(by_package)
    table.sort(packages)
    local total = 0
    for _, ids in pairs(by_package) do
        total = total + #ids
    end
    health.ok(("%d log rules over %d packages: %s"):format(total, #packages, table.concat(packages, ", ")))
    if #config.diagnostics.rules > 0 then
        health.info(
            ("%d user rule(s) from diagnostics.rules are appended after the shipped set"):format(
                #config.diagnostics.rules
            )
        )
    end
end

--- Report config values that are internally inconsistent.
---@param health table
---@return nil
local function check_config(health)
    local qf = config.diagnostics.quickfix
    if qf ~= "never" and qf ~= "on_error" and qf ~= "always" then
        health.error(("diagnostics.quickfix = %q — expected never|on_error|always"):format(tostring(qf)))
    end
    local subfiles = config.root.subfiles
    if subfiles ~= "root" and subfiles ~= "subfile" then
        health.error(("root.subfiles = %q — expected root|subfile"):format(tostring(subfiles)))
    end
    if config.continuous.timeout and config.continuous.timeout <= 0 then
        health.warn("continuous.timeout is not positive — a wedged build will never be killed")
    end
    if not config.keys.prefix or config.keys.prefix == "" then
        health.warn("keys.prefix is empty — no lvim-tex keymaps will be installed")
    end
end

--- THIS MACHINE's viewer matrix: every viewer the plugin knows, what state it is in here, and what
--- it can do. A viewer story is full of one-time steps that live inside the viewer's own settings, so
--- health is the place that must be honest about three distinct states — not implemented in this
--- version, implemented but not installed here, and ready — rather than collapsing them into "no".
---@param health table
---@return nil
local function check_viewers(health)
    if not config.viewer.enabled then
        health.warn("viewer.enabled = false — lvim-tex builds but never opens a viewer")
    end

    local chosen, err = viewer.resolve()
    if chosen then
        health.ok(
            ("viewer in use: %s%s"):format(
                chosen.name,
                config.viewer.name == "auto" and (" (auto, from %s)"):format(table.concat(viewer.priority(), " → "))
                    or " (named in config)"
            )
        )
    else
        health.error(err or "no viewer available")
    end

    -- Three states must stay distinguishable: not implemented here, implemented but unproven on this
    -- platform, and proven. Collapsing them into ok/not-ok is what makes a viewer story untrustworthy.
    ---@type table<string, string>
    local PROVEN = {
        live = "verified on this machine",
        docs = "per the viewer's documentation; not installed here to verify",
        platform = "per the viewer's documentation; needs its own platform to verify",
        experimental = "EXPERIMENTAL — its D-Bus interface has not been exercised anywhere yet",
    }
    for _, row in ipairs(viewer.matrix()) do
        if not row.implemented then
            health.info(("%s — planned, not in this version"):format(row.name))
        elseif row.available then
            local line = ("%s — available (reload: %s, inverse: %s) · %s"):format(
                row.name,
                row.reload,
                row.inverse and "yes" or "no",
                PROVEN[row.verified] or row.verified
            )
            if row.verified == "live" then
                health.ok(line)
            else
                health.warn(line)
            end
        else
            -- The caveat belongs on an ABSENT viewer too: it is what the user is deciding about when
            -- they consider installing it.
            local caveat = (row.verified ~= "live") and ("  (%s)"):format(PROVEN[row.verified] or "") or ""
            health.info(("%s — %s%s"):format(row.name, row.detail or "not found on this machine", caveat))
        end
    end
end

--- SyncTeX: the utility itself, whether this instance can be reached back, and the one manual step
--- each viewer still needs. A viewer story that says "inverse search: yes" without naming the step is
--- the reason inverse search has a reputation for never working.
---@param health table
---@return nil
local function check_synctex(health)
    local ok, detail = synctex.available()
    if ok then
        health.ok(("synctex (%s)"):format(config.synctex.bin))
    else
        health.warn(detail or "synctex is unavailable", {
            "forward and inverse search need it; it ships with every TeX distribution",
        })
    end

    if not config.synctex.inverse then
        health.info("synctex.inverse = false — a click in the viewer will not move the cursor")
        return
    end

    if not vim.v.servername or vim.v.servername == "" then
        health.warn("this Neovim has no server socket — an external viewer cannot reach it", {
            'started with `--listen ""`? inverse search from an external viewer needs the socket',
        })
    end

    -- Our own page reaches the editor over lvim-preview's websocket, behind ITS gate. That gate is a
    -- setting in lvim-preview's config, and this plugin does not write another plugin's config — so
    -- health prints the line instead.
    local ok_preview, prev_config = pcall(require, "lvim-preview.config")
    if ok_preview and type(prev_config) == "table" then
        if prev_config.artifact and prev_config.artifact.allow_client_messages then
            health.ok("lvim-preview accepts inbound messages — ctrl-click in the page jumps here")
        else
            health.warn("lvim-preview's inbound-message gate is closed — ctrl-click in the page does nothing", {
                'add `artifact = { allow_client_messages = true }` to require("lvim-preview").setup()',
                "it stays per-artifact: only a producer that registered a handler (this one) is delivered to",
            })
        end
    end

    local skim = viewer.module("skim")
    if skim and skim.available() and type(skim.inverse_setup) == "function" then
        local setup = skim.inverse_setup()
        health.info("Skim needs a one-time setting — Preferences → Sync → Custom:")
        health.info(("    Command:   %s"):format(setup.command))
        health.info(("    Arguments: %s"):format(setup.arguments))
    end
end

--- :checkhealth lvim-tex
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-tex")
    check_builder(health)
    check_grammars(health)
    check_lsp(health)
    check_rules(health)
    check_config(health)
    health.start("lvim-tex: viewers")
    check_viewers(health)
    check_synctex(health)
    health.start("lvim-tex: project")
    check_project(health)
end

return M
