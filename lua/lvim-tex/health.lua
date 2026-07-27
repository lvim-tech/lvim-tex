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
local state = require("lvim-tex.state")

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

    -- A backend's LIMITS are data on the module (`supports`), so health states them rather than
    -- leaving the user to discover them as a build that silently produced nothing.
    local supports = mod.supports or {}
    if supports.oneshot == false then
        health.warn(
            ("%s is an engine AND a viewer in one long-lived process: it writes no PDF, produces no log and never exits, so it cannot be run as a build"):format(
                name
            ),
            { "set config.builder to latexmk, tectonic, latexrun or arara for the batch build" }
        )
    end
    if supports.out_dir == false and config.out_dir and config.out_dir ~= "" then
        health.warn(
            ("%s cannot write into an output directory — it builds beside the source, but out_dir = %q"):format(
                name,
                config.out_dir
            ),
            { "lvim-tex already builds beside the source for it; set out_dir = false so the project agrees" }
        )
    end
    if supports.clean == "all" then
        health.info(
            ("%s has ONE clean action: `:LvimTex clean` and `:LvimTex clean full` both remove the PDF"):format(name)
        )
    elseif supports.clean == false then
        health.info(("%s has no clean action of its own — `:LvimTex clean` says so"):format(name))
    end
end

--- Where a selection compile (`,lL`) puts its scratch project, and whether it will be shown.
---@param health table
---@return nil
local function check_selection(health)
    local dir = config.selection.dir
    if not dir or dir == "" then
        dir = fn.stdpath("cache") .. "/lvim-tex/selection"
    end
    health.info(("selection compile: scratch projects under %s"):format(fn.fnamemodify(dir, ":~")))
    if not config.selection.view then
        health.info("selection.view = false — a compiled selection is built but not shown")
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

    -- THE TRAP WORTH NAMING. The follow only ever moves a viewer showing THIS project's PDF, and for
    -- a single-instance viewer that is decided by comparing the document on screen with the compile
    -- target's PDF. Reading a chapter's PDF while the target is still the root is therefore a state
    -- in which everything is configured correctly and nothing follows — indistinguishable, from the
    -- outside, from a broken link. `,ls` (toggle the compile target) is what aligns them.
    if chosen and chosen.supports.status ~= true then
        local buf = tex_buffer()
        local root = buf and root_mod.of(buf) or nil
        if root then
            local target = state.project(root).target or root
            local pdf = root_mod.pdf(root, target)
            health.info(("the follow tracks %s — the compile target's PDF"):format(fn.fnamemodify(pdf, ":~")))
            if target ~= root then
                health.info(
                    ("compile target is the subfile %s (`,ls` toggles it)"):format(fn.fnamemodify(target, ":t"))
                )
            else
                health.info(
                    "a viewer showing a DIFFERENT document will not follow — `,ls` to compile the file you read"
                )
            end
        end
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
            -- `forward` decides whether the CURSOR-FOLLOW may drive this viewer at all, so it belongs
            -- in the same line as reload and inverse: "raises" is not a defect, it is the reason a
            -- perfectly working viewer does not follow the cursor, and the user should read it here
            -- rather than deduce it.
            local FOLLOW = {
                quiet = "follows the cursor",
                raises = "explicit `,lv` only — its sync always takes the focus",
            }
            -- zathura's raise is a SETTING, so "raises" here is a choice the user can reverse; naming
            -- the knob is the difference between a report and an explanation.
            if row.name == "zathura" and row.forward == "raises" then
                health.info(
                    '  zathura: set `viewer = { zathura = { forward = "quiet" } }` to make it follow the cursor'
                        .. " (lvim-tex then turns zathura's own `dbus-raise-window` off in the window it opens)"
                )
            end
            local line = ("%s — available (reload: %s, inverse: %s, forward: %s) · %s"):format(
                row.name,
                row.reload,
                row.inverse and "yes" or "no",
                FOLLOW[row.forward] or "not supported",
                PROVEN[row.verified] or row.verified
            )
            if row.verified == "live" then
                health.ok(line)
            else
                health.warn(line)
            end
            -- An INSTALLED viewer can still carry a caveat (a missing D-Bus helper, a renderer that
            -- cannot load) — `available` returns it alongside true, and dropping it here is how a
            -- viewer that opens an empty window gets reported as ready.
            if row.detail then
                health.warn(("  %s: %s"):format(row.name, row.detail))
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
        local back = config.synctex.follow_back or {}
        if prev_config.artifact and prev_config.artifact.allow_client_messages then
            health.ok("lvim-preview accepts inbound messages — ctrl-click in the page jumps here")
            -- The gate carries BOTH inbound shapes; which of them is acted on is this plugin's own
            -- setting, so report the two separately rather than implying one answer covers both.
            if back.enabled then
                health.ok(
                    ("scrolling the page moves the source with it (synctex.follow_back: %s, settle %dms)"):format(
                        back.move == "cursor" and "cursor" or "view only",
                        back.settle or 300
                    )
                )
            else
                health.info("synctex.follow_back.enabled = false — scrolling the page leaves the source alone")
            end
            -- The coarse half is a separate switch and a separate capability, so it is reported
            -- separately: "the link is on" does not answer "will THIS viewer follow".
            local poll = back.poll or {}
            -- This section is about SyncTeX, not viewers, so it resolves its own — `chosen` belongs
            -- to the viewer section and reaching for it here only looks like it works.
            local driven = viewer.resolve()
            if poll.enabled and back.enabled then
                if driven and driven.supports.position == true then
                    health.ok(
                        ("%s is polled for its page every %dms — the source follows a page flip"):format(
                            driven.name,
                            math.max(100, tonumber(poll.interval) or 1000)
                        )
                    )
                elseif driven then
                    health.info(
                        ("%s cannot report which page it is on — the page poll does nothing here"):format(driven.name)
                    )
                end
            elseif driven and driven.supports.position == true and back.enabled then
                health.info(
                    ("%s could follow by the page — set `synctex.follow_back.poll.enabled = true`"):format(
                        driven.name
                    )
                )
            end
        else
            health.warn("lvim-preview's inbound-message gate is closed — the page cannot reach the editor", {
                'add `artifact = { allow_client_messages = true }` to require("lvim-preview").setup()',
                "it gates BOTH directions in: ctrl-click inverse search and the scroll link (synctex.follow_back)",
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

--- Report what the navigation layer can and cannot resolve in THIS project: the structure it reads,
--- and — the actionable part — every include that resolves to nothing, which is exactly what makes a
--- TOC row or a `gf` fail.
---@param health table
---@return nil
local function check_navigation(health)
    if config.nav.kpsewhich and fn.executable(config.nav.kpsewhich) == 1 then
        health.ok(
            ("%s found — `gf` on \\usepackage / \\documentclass opens the distribution's file"):format(
                config.nav.kpsewhich
            )
        )
    else
        health.info("kpsewhich not found — `gf` resolves project files only (it ships with every TeX distribution)")
    end
    local buf = tex_buffer()
    local root = buf and root_mod.of(buf) or nil
    if not root then
        return
    end
    local structure = require("lvim-tex.structure")
    local entries = structure.document(root)
    local counts, missing = { section = 0, include = 0, label = 0, todo = 0 }, {}
    for _, entry in ipairs(entries) do
        counts[entry.kind] = (counts[entry.kind] or 0) + 1
        if entry.kind == "include" and not entry.target then
            missing[#missing + 1] = ("%s (%s:%d)"):format(entry.title, fn.fnamemodify(entry.file, ":t"), entry.lnum)
        end
    end
    health.info(
        ("structure: %d sections, %d includes, %d labels, %d todos"):format(
            counts.section,
            counts.include,
            counts.label,
            counts.todo
        )
    )
    if #missing > 0 then
        health.warn("includes that resolve to no file:", missing)
    end
end

--- The editing half (E1-E7, S6-S8): the queries this plugin ships have to RESOLVE (they live under
--- `after/`, which is a runtimepath entry of its own), and the query indent needs lvim-ts's engine.
---@param health table
---@return nil
local function check_editing(health)
    for _, name in ipairs({ "textobjects", "indents", "injections" }) do
        if vim.treesitter.query.get("latex", name) then
            health.ok(("latex %s query resolves"):format(name))
        else
            health.warn(
                ("latex %s query does not resolve — lvim-tex's after/queries are not on the runtimepath"):format(name)
            )
        end
    end
    local report = require("lvim-tex.syntax").report()
    if report.folds_query then
        health.ok(
            ("folding: %s (fold.enabled = %s)"):format(report.fold and "on" or "off", tostring(config.fold.enabled))
        )
    else
        health.warn("the latex folds query is missing — folding cannot be enabled")
    end
    if report.engine then
        health.ok(("indent: %s (query + lvim-ts engine)"):format(report.indent and "on" or "off"))
    else
        health.warn("lvim-ts is not available — the shipped indents query has no engine to run in", {
            "install lvim-ts; without it 'indentexpr' falls back to Neovim's own tex indent",
        })
    end
    health.ok(("matching-pair highlight: %s"):format(config.matchparen.enabled and "on" or "off"))
end

--- Conceal: whether it can run at all (it is treesitter-driven, so no latex grammar means no
--- conceal), what is switched on, and how many commands the merged maps cover. A swallowed renderer
--- error is reported here rather than breaking a redraw, which is why it is kept at all.
---@param health table
---@return nil
local function check_conceal(health)
    local status = require("lvim-tex.conceal").status(tex_buffer() or 0)
    if not status.parser then
        health.warn("conceal needs the latex grammar, which is not installed", {
            'add "latex" to lvim-ts `ensure_installed`',
        })
        return
    end
    local on, off = {}, {}
    for group, enabled in pairs(status.groups) do
        table.insert(enabled and on or off, group)
    end
    table.sort(on)
    table.sort(off)
    health.ok(("conceal: %d commands over %d groups"):format(status.commands, #on))
    health.info(("groups on:  %s"):format(#on > 0 and table.concat(on, ", ") or "none"))
    health.info(("groups off: %s"):format(#off > 0 and table.concat(off, ", ") or "none"))
    health.info(
        ("conceallevel %d, concealcursor %q while a TeX buffer is displayed"):format(status.level, status.cursor)
    )
    if not config.conceal.enabled then
        health.info("conceal.enabled = false — turn it on per buffer with `:LvimTex conceal`")
    end
    if status.error then
        health.error(("the conceal renderer failed: %s"):format(status.error))
    end
end

--- Completion (K1-K6) and the gap-fill. Those rows are DELEGATED, so the first honest answer is
--- whether texlab actually REACHED the user's document — `check_lsp` says the binary exists, this
--- says it attached. Then the narrow strip lvim-tex serves itself, named command by command, so
--- "why does \nameref complete but \zref not" has an answer that is not the source code.
---@param health table
---@return nil
local function check_completion(health)
    local completion = require("lvim-tex.completion")
    local attached, name = completion.server(tex_buffer())
    if attached then
        health.ok(("%s is attached — cite, label, command, package, glossary and path completion"):format(name))
    elseif completion.server_installed() then
        health.warn("texlab is installed but has not attached to the TeX buffer — completion will be empty", {
            "open a .tex file; lvim-lang's latex provider starts texlab on FileType",
        })
    end
    if not config.completion.enabled then
        health.info("completion.enabled = false — the gap-fill source is not registered")
        return
    end
    if not pcall(require, "lvim-cmp") then
        health.info("lvim-cmp is not installed — the gap-fill source has nowhere to register")
        return
    end
    local served = completion.served()
    local kinds = vim.tbl_keys(served)
    table.sort(kinds)
    local total = 0
    for _, kind in ipairs(kinds) do
        total = total + #served[kind]
    end
    health.ok(("completion gap-fill: %d commands texlab does not serve, over %d data sets"):format(total, #kinds))
    for _, kind in ipairs(kinds) do
        local commands = vim.tbl_map(function(command)
            return "\\" .. command
        end, served[kind])
        health.info(("  %-10s %s"):format(kind, table.concat(commands, " ")))
    end
    health.info(("it runs ONLY as a fallback for: %s"):format(table.concat(config.completion.fallback_for or {}, ", ")))
end

--- texcount and texdoc — the two external tools the word count (M2) and the documentation lookup
--- (M1) drive. Neither is fatal: every other feature works without them.
---@param health table
---@return nil
local function check_tools(health)
    if fn.executable(config.count.bin) == 1 then
        health.ok(
            ("%s found — `:LvimTex count` runs `%s`"):format(
                config.count.bin,
                table.concat(vim.list_extend({ config.count.bin }, config.count.args or {}), " ")
            )
        )
    else
        health.warn(("%s is not on PATH — `:LvimTex count` cannot run"):format(config.count.bin), {
            "it ships with every TeX distribution (TeX Live: the texlive-binextra collection)",
        })
    end
    if fn.executable(config.docs.bin) == 1 then
        health.ok(("%s found — `:LvimTex doc`"):format(config.docs.bin))
    else
        health.warn(("%s is not on PATH — `:LvimTex doc` cannot run"):format(config.docs.bin), {
            "it ships with every TeX distribution (TeX Live: the texlive-texdoc package)",
        })
    end
end

--- The maths abbreviations (E9) and the shipped snippet collection (E10). Both live in lvim-snippets
--- — the rules as postfix rules, the collection as a registered root — so "why does nothing expand"
--- has four separate answers, and this separates them: no lvim-snippets, its postfix engine off,
--- `imaps.enabled = false`, or a trigger shadowed by a shorter one.
---@param health table
---@return nil
local function check_imaps(health)
    local imaps = require("lvim-tex.imaps")
    local stats = imaps.stats()
    if not stats.snippets then
        health.warn(
            "lvim-snippets is not installed — the maths abbreviations and the snippet collection do nothing",
            {
                "install lvim-snippets (it owns the expansion engine; lvim-tex only registers into it)",
            }
        )
    elseif not stats.enabled then
        health.info(
            ("imaps.enabled = false — %d abbreviations ready, `:LvimTex imaps` lists them"):format(stats.total)
        )
    elseif not stats.engine then
        health.warn("lvim-snippets' postfix engine is off, so no abbreviation can fire", {
            'require("lvim-snippets").setup({ postfix = { enabled = true } })',
        })
    else
        health.ok(
            ("maths abbreviations: %d registered, leader %q, expanding inside maths only"):format(
                stats.installed,
                stats.leader
            )
        )
    end
    for _, pair in ipairs(stats.shadowed) do
        health.warn(
            ("the trigger %q can never fire: %q is a prefix of it and expands first"):format(pair[2], pair[1]),
            { "abbreviations auto-expand, so no trigger may be a prefix of another — rename or disable one" }
        )
    end

    local collection = require("lvim-tex.snippets").stats()
    if not config.snippets.enabled then
        health.info("snippets.enabled = false — the shipped tex collection is not registered")
    elseif collection.registered then
        health.ok(("snippet collection registered: %s"):format(collection.dir))
        health.info(
            ("%d `tex` snippets reachable through lvim-snippets (this collection plus your own roots)"):format(
                collection.records
            )
        )
    else
        health.warn(("the shipped snippet collection is not registered: %s"):format(collection.reason or "unknown"), {
            "it registers itself from setup(); check that lvim-snippets is installed and up to date",
        })
    end
end

--- :checkhealth lvim-tex
---@return nil
function M.check()
    local health = vim.health
    health.start("lvim-tex")
    check_builder(health)
    check_selection(health)
    check_grammars(health)
    check_lsp(health)
    check_completion(health)
    check_rules(health)
    check_navigation(health)
    check_editing(health)
    check_config(health)
    check_conceal(health)
    check_imaps(health)
    check_tools(health)
    health.start("lvim-tex: viewers")
    check_viewers(health)
    check_synctex(health)
    health.start("lvim-tex: project")
    check_project(health)
end

return M
