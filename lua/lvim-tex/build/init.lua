-- lvim-tex: the build lifecycle — the one place that knows a build is running.
--
-- Everything here exists because a LaTeX build is slow, repeatable and easy to start twice. The
-- rules it enforces:
--
--   SINGLE-FLIGHT — one build per project at a time. A request that arrives while a build is in
--     flight does not queue up N times; it sets ONE pending flag, so a burst of saves collapses into
--     "the run in progress" plus "one more run afterwards". This is why we do not use latexmk's own
--     `-pvc` watch mode: scheduling stays ours, and there is no long-lived child to babysit.
--   WATCHDOG — a run that exceeds `continuous.timeout` is killed. A TeX engine waiting for terminal
--     input (which `-interaction=nonstopmode` normally prevents, but a broken `.latexmkrc` can still
--     produce) would otherwise hang forever inside a job with no tty.
--   ATTRIBUTED DIAGNOSTICS — the log's entries belong to whichever file they name, which is usually
--     NOT the buffer that triggered the build. They are published per file, and every buffer touched
--     by the previous run is cleared first, so a fixed error disappears from the chapter it was in.
--   EVENTS — `User LvimTexBuildStart` / `LvimTexBuildDone` carry the project data, so a statusline,
--     a panel or a viewer can react without polling.
--
---@module "lvim-tex.build"

local config = require("lvim-tex.config")
local state = require("lvim-tex.state")
local root_mod = require("lvim-tex.root")
local log = require("lvim-tex.log")
local viewer = require("lvim-tex.viewer")

local api = vim.api
local fn = vim.fn
local uv = vim.uv

local M = {}

local S = vim.diagnostic.severity

-- Severity → the quickfix `type` character.
---@type table<integer, string>
local QF_TYPE = { [S.ERROR] = "E", [S.WARN] = "W", [S.INFO] = "I", [S.HINT] = "N" }

--- Notify, gated by `config.notify`.
---@param msg string
---@param level integer?
---@return nil
local function notify(msg, level)
    if config.notify then
        vim.notify("lvim-tex: " .. msg, level or vim.log.levels.INFO)
    end
end

--- Fire a `User` autocmd carrying the project data.
---@param name string   the pattern ("LvimTexBuildStart" / "LvimTexBuildDone")
---@param data table
---@return nil
local function emit(name, data)
    api.nvim_exec_autocmds("User", { pattern = name, data = data, modeline = false })
end

--- The backend module for `name`, or nil with a reason when it is not implemented yet.
---@param name string
---@return table? mod, string? err
local function backend(name)
    local ok, mod = pcall(require, "lvim-tex.build." .. name)
    if not ok or type(mod) ~= "table" then
        return nil, ("builder %q is not available in this version"):format(name)
    end
    return mod, nil
end

--- The diagnostic namespace, created on first use.
---@return integer
local function namespace()
    if not state.ns then
        state.ns = api.nvim_create_namespace("lvim-tex")
    end
    return state.ns
end

--- Publish `items` as diagnostics, replacing everything the previous run of this project published.
---@param root string
---@param items LvimTexItem[]
---@return nil
local function publish(root, items)
    local project = state.project(root)
    local ns = namespace()

    -- Clear the buffers the LAST run wrote to, not just the ones this run touches: an entry that was
    -- fixed leaves no item behind to clear itself.
    for buf in pairs(project.diag_bufs or {}) do
        if api.nvim_buf_is_valid(buf) then
            vim.diagnostic.reset(ns, buf)
        end
    end
    project.diag_bufs = {}
    project.diags = items

    if not config.diagnostics.enabled then
        return
    end

    ---@type table<integer, table[]>
    local by_buf = {}
    for _, item in ipairs(items) do
        -- `bufadd` gives an entry in the buffer list WITHOUT loading the file, so diagnostics for a
        -- chapter the user has not opened yet are already there when they open it.
        local buf = fn.bufadd(item.file)
        if buf ~= 0 then
            by_buf[buf] = by_buf[buf] or {}
            table.insert(by_buf[buf], {
                lnum = math.max(item.lnum - 1, 0),
                col = math.max(item.col - 1, 0),
                severity = item.severity,
                message = item.message,
                source = "lvim-tex",
                code = item.rule,
            })
        end
    end

    for buf, diags in pairs(by_buf) do
        vim.diagnostic.set(ns, buf, diags)
        project.diag_bufs[buf] = true
    end
end

--- Fill the quickfix list from `items` and open it according to `diagnostics.quickfix`.
---@param root string
---@param items LvimTexItem[]
---@return nil
local function quickfix(root, items)
    local mode = config.diagnostics.quickfix
    if mode == "never" then
        return
    end
    local qf, errors = {}, 0
    for _, item in ipairs(items) do
        if item.severity == S.ERROR then
            errors = errors + 1
        end
        qf[#qf + 1] = {
            filename = item.file,
            lnum = item.lnum,
            col = item.col,
            text = item.message,
            type = QF_TYPE[item.severity] or "I",
        }
    end
    fn.setqflist({}, "r", { title = ("lvim-tex: %s"):format(fn.fnamemodify(root, ":t")), items = qf })
    if mode == "always" and #qf > 0 then
        vim.cmd("botright copen")
    elseif mode == "on_error" and errors > 0 then
        vim.cmd("botright copen")
    end
end

--- Stop the watchdog timer of `build`, if one is armed.
---@param build LvimTexBuild
---@return nil
local function disarm(build)
    if build.watchdog then
        build.watchdog:stop()
        if not build.watchdog:is_closing() then
            build.watchdog:close()
        end
        build.watchdog = nil
    end
end

--- Arm the watchdog for a run: kill the child if it outlives `continuous.timeout`.
---@param build LvimTexBuild
---@param handle vim.SystemObj
---@param label string  the target's basename, for the message
---@return nil
local function arm(build, handle, label)
    local timeout = config.continuous.timeout
    if not timeout or timeout <= 0 then
        return
    end
    local timer = uv.new_timer()
    if not timer then
        return
    end
    build.watchdog = timer
    timer:start(timeout, 0, function()
        vim.schedule(function()
            if build.job then
                handle:kill("sigterm")
                notify(
                    ("%s build of %s exceeded %dms and was killed"):format(config.icons.fail, label, timeout),
                    vim.log.levels.WARN
                )
            end
        end)
    end)
end

--- The first ERROR of a run, as a one-line summary for a viewer's error strip: the file it is in and
--- the message, which is what makes the strip actionable without opening the panel.
---@param items table[]
---@return string?
local function first_error(items)
    for _, item in ipairs(items) do
        if item.severity == S.ERROR then
            return ("%s:%d  %s"):format(vim.fs.basename(item.file), item.lnum, item.message)
        end
    end
    return nil
end

---@param build LvimTexBuild
---@return integer  milliseconds the last run took (0 when it never ran)
local function duration_ms(build)
    if not (build.started and build.finished) then
        return 0
    end
    return math.floor((build.finished - build.started) / 1e6)
end

--- Compile the project rooted at `root`. Every entry point funnels through here, so a rerun is
--- always started against the project it belongs to and never against "whatever buffer is current".
---@param root string
---@param opts { silent?: boolean }
---@return boolean started
local function start(root, opts)
    local project = state.project(root)
    local target = project.target
    local label = fn.fnamemodify(target, ":t")

    -- SINGLE-FLIGHT: never a second child for the same project; one pending rerun at most.
    if project.build.job then
        project.build.pending = true
        if not opts.silent then
            notify(("%s %s is already building — one rerun queued"):format(config.icons.building, label))
        end
        return false
    end

    -- The `% !TEX program` directive lives in the PREAMBLE, so a subfile has none — ask the project
    -- (root first-class, target override) or a toggled chapter compiles with the wrong engine.
    local name = root_mod.program_for(root, target) or config.builder
    local mod, err = backend(name)
    if not mod then
        notify(err or "no builder", vim.log.levels.ERROR)
        return false
    end
    local ok_bin, detail = mod.available()
    if not ok_bin then
        notify(detail or ("%s is unavailable"):format(name), vim.log.levels.ERROR)
        return false
    end

    -- A SESSION backend (texpresso) is an engine and a viewer in one long-lived process: it writes no
    -- log, produces no PDF and never exits, so nothing below — the watchdog, the log parse, the viewer
    -- artifact — can own it. Refuse it here rather than spawn a window the watchdog kills two minutes
    -- later and report it as a failed build.
    if mod.supports and mod.supports.oneshot == false then
        notify(("builder %q is a live session, not a batch build"):format(name), vim.log.levels.WARN)
        return false
    end

    local out_dir = root_mod.out_dir(root, target)
    if out_dir ~= vim.fs.dirname(target) and not uv.fs_stat(out_dir) then
        -- latexmk refuses to create its own out-dir, so a first build into a fresh `build/` would
        -- fail with an error that says nothing about the real cause.
        fn.mkdir(out_dir, "p")
    end

    local argv = mod.argv({
        target = target,
        out_dir = (out_dir ~= vim.fs.dirname(target)) and out_dir or nil,
        engine = root_mod.engine_for(root, target),
    })

    project.build.status = "building"
    project.build.pending = false
    project.build.output = {}
    project.build.started = uv.hrtime()
    project.build.finished = nil
    project.build.code = nil

    emit("LvimTexBuildStart", { root = root, target = target, builder = name })
    -- The viewer learns a build began BEFORE the child is spawned: a page that can show our state
    -- should say "building" for the whole run, not from the moment the run happens to finish.
    viewer.on_build_start(root)
    if not opts.silent then
        notify(("%s building %s"):format(config.icons.building, label))
    end

    local handle = vim.system(argv, {
        cwd = mod.cwd({ target = target }),
        env = mod.env(),
        text = true,
    }, function(result)
        vim.schedule(function()
            M._finish(root, name, result)
        end)
    end)

    project.build.job = handle
    project.build.pid = handle.pid
    arm(project.build, handle, label)
    return true
end

-- ── the continuous loop (save-driven, ours — not latexmk's `-pvc`) ───────────────────────────────────

--- Release a project's debounce timer. Stopping alone keeps the uv handle alive, so a session that
--- opens many projects would accumulate one per root.
---@param root string
---@return nil
local function release_debounce(root)
    local p = state.projects[root]
    local timer = p and p.debounce
    if not timer then
        return
    end
    timer:stop()
    if not timer:is_closing() then
        timer:close()
    end
    p.debounce = nil
end

--- Is the continuous loop ARMED for this project?
---
--- Three inputs, in order: `continuous.enabled` is the master switch; a project the user has TOGGLED
--- keeps whatever they chose; a project nobody has toggled takes `continuous.auto_start`. That last
--- step is why the per-project flag starts as nil rather than false — with a plain boolean there is no
--- way to tell "the user turned it off" from "the user never said", and `auto_start` could then only
--- be applied by an autocmd racing whatever else touches the project first.
---@param root string
---@return boolean
function M.is_continuous(root)
    if config.continuous.enabled ~= true then
        return false
    end
    local decided = state.project(root).build.continuous
    if decided == nil then
        return config.continuous.auto_start == true
    end
    return decided == true
end

--- Toggle the loop for the project `buf` belongs to. Returns the new state (nil = no project).
---@param buf integer?
---@return boolean?
function M.toggle_continuous(buf)
    local root = root_mod.of(buf)
    if not root then
        notify("this buffer has no file on disk", vim.log.levels.WARN)
        return nil
    end
    if not config.continuous.enabled then
        notify("the continuous loop is disabled (continuous.enabled = false)", vim.log.levels.WARN)
        return false
    end
    local project = state.project(root)
    -- Toggle the EFFECTIVE state, not the stored one: for an untouched project the effective state is
    -- `auto_start`, so the first press must turn that off rather than agree with it.
    project.build.continuous = not M.is_continuous(root)
    if not project.build.continuous then
        release_debounce(root) -- a queued rebuild must not fire after the loop was turned off
    end
    notify(
        ("%s continuous build %s for %s"):format(
            project.build.continuous and config.icons.ok or config.icons.fail,
            project.build.continuous and "on" or "off",
            fn.fnamemodify(root, ":t")
        )
    )
    return project.build.continuous
end

--- A file was written: rebuild the project it belongs to, if the loop is armed and the file is one the
--- build actually READS.
---
--- The watch set is latexmk's own dependency record (see `root.watch`), which is why a changed `.bib`,
--- `.sty` or generated input triggers a rebuild while an unrelated file in the same directory does not.
--- Before the first build there is no such record and the include graph stands in.
---@param path string  the written file, absolute
---@param buf integer
---@return nil
function M.on_write(path, buf)
    if not config.continuous.on_save then
        return
    end
    local root = root_mod.of(buf)
    if not root or not M.is_continuous(root) then
        return
    end
    local project = state.project(root)
    local watched = false
    for _, f in ipairs(root_mod.watch(root, project.target, root_mod.out_dir(root, project.target))) do
        if f == path then
            watched = true
            break
        end
    end
    if not watched then
        return
    end
    -- DEBOUNCE, not a build per keystroke-of-save: `:wa` over five files is one rebuild, not five. The
    -- single-flight rule in `start` then collapses whatever still overlaps.
    release_debounce(root)
    local timer = vim.uv.new_timer()
    if not timer then
        return
    end
    project.debounce = timer
    timer:start(
        math.max(0, config.continuous.debounce or 250),
        0,
        vim.schedule_wrap(function()
            release_debounce(root)
            if M.is_continuous(root) then
                start(root, { silent = true })
            end
        end)
    )
end

--- Compile the project `buf` belongs to — its current target, which is the root document unless the
--- user toggled the target to the subfile they are editing (`:LvimTex main`).
---@param buf integer?
---@param opts { silent?: boolean }?
---@return boolean started
function M.build(buf, opts)
    local root = root_mod.of(buf)
    if not root then
        notify("this buffer has no file on disk", vim.log.levels.WARN)
        return false
    end
    return start(root, opts or {})
end

--- Post-run handling: parse the log, publish, report, and honour a pending rerun. Internal, but
--- named on the module so the headless proofs can drive it with a captured result.
---@param root string
---@param builder string
---@param result vim.SystemCompleted
---@return nil
function M._finish(root, builder, result)
    local project = state.project(root)
    local build = project.build

    disarm(build)
    build.job = nil
    build.pid = nil
    build.finished = uv.hrtime()
    build.code = result.code
    build.status = result.code == 0 and "ok" or "failed"

    -- Keep a bounded tail of the raw output: enough for the build panel and `:LvimTex info`, never
    -- the whole transcript of a big document.
    local raw = vim.split((result.stdout or "") .. (result.stderr or ""), "\n", { plain = true })
    local keep = config.output_lines
    build.output = #raw > keep and vim.list_slice(raw, #raw - keep + 1, #raw) or raw

    -- The `.fls` list only exists after a successful run; refresh the watch set from it now.
    project.watch = nil

    -- The log is named after the TARGET (a toggled subfile has its own), and lives in the build
    -- directory while its relative paths stay relative to the target's own directory.
    local items = log.parse(project.target, root_mod.out_dir(root, project.target))
    publish(root, items)
    quickfix(root, items)

    local errors = 0
    for _, item in ipairs(items) do
        if item.severity == vim.diagnostic.severity.ERROR then
            errors = errors + 1
        end
    end

    emit("LvimTexBuildDone", {
        root = root,
        builder = builder,
        code = result.code,
        errors = errors,
        duration = duration_ms(build),
    })

    -- The viewer is told what happened, in its own vocabulary: refetch on success, an error strip
    -- over the LAST GOOD render on failure. The strip carries the first error, not the whole list —
    -- the diagnostics live in the editor and the page is not a second place to read them.
    viewer.on_build_done(root, result.code == 0, first_error(items) or ("build failed (exit %d)"):format(result.code))

    -- Name what was COMPILED, not the project: with the target toggled to a subfile, "main.tex failed"
    -- points at a file that was never handed to the engine.
    local label = fn.fnamemodify(project.target, ":t")
    if result.code == 0 then
        notify(("%s %s built in %dms"):format(config.icons.ok, label, duration_ms(build)))
    else
        notify(
            ("%s %s failed (%d error%s)"):format(config.icons.fail, label, errors, errors == 1 and "" or "s"),
            vim.log.levels.WARN
        )
    end

    if build.pending then
        build.pending = false
        -- The rerun is silent: the user already saw the first build's messages, and this one was
        -- triggered by their save, not by a new request. It targets the same ROOT, never "the current
        -- buffer", which may by now be an unrelated file.
        start(root, { silent = true })
    end
end

--- Stop the build of the project `buf` belongs to.
---@param buf integer?
---@return boolean stopped
function M.stop(buf)
    local root = root_mod.of(buf)
    if not root then
        return false
    end
    local build = state.project(root).build
    if not build.job then
        return false
    end
    -- SIGTERM lets latexmk clean up its own temporary state; the exit callback does the bookkeeping.
    build.job:kill("sigterm")
    build.pending = false
    notify(("%s stopped %s"):format(config.icons.fail, fn.fnamemodify(root, ":t")))
    return true
end

--- Stop every running build.
---@return integer count
function M.stop_all()
    local count = 0
    for _, root in ipairs(state.active_roots()) do
        local build = state.project(root).build
        if build.job then
            build.job:kill("sigterm")
            build.pending = false
            count = count + 1
        end
    end
    if count > 0 then
        notify(("%s stopped %d build%s"):format(config.icons.fail, count, count == 1 and "" or "s"))
    end
    return count
end

--- Remove the build's auxiliary files (`full` also removes the produced PDF).
---@param buf integer?
---@param full boolean?
---@return boolean started
function M.clean(buf, full)
    local root = root_mod.of(buf)
    if not root then
        return false
    end
    local name = root_mod.program(root) or config.builder
    local mod = backend(name)
    if not mod or not mod.clean_argv then
        notify(("builder %q cannot clean"):format(name), vim.log.levels.WARN)
        return false
    end
    local out_dir = root_mod.out_dir(root)
    local argv = mod.clean_argv({
        target = root,
        out_dir = (out_dir ~= vim.fs.dirname(root)) and out_dir or nil,
        full = full,
    })
    vim.system(argv, { cwd = mod.cwd({ target = root }), text = true }, function(result)
        vim.schedule(function()
            if result.code == 0 then
                notify(("%s cleaned %s"):format(config.icons.ok, fn.fnamemodify(root, ":t")))
            else
                notify(
                    ("%s clean failed: %s"):format(config.icons.fail, vim.trim(result.stderr or "")),
                    vim.log.levels.WARN
                )
            end
        end)
    end)
    return true
end

--- A one-line status for the project `buf` belongs to (used by `:LvimTex info` and the hud segment).
---@param buf integer?
---@return string
function M.status_text(buf)
    local root = root_mod.of(buf)
    if not root then
        return ""
    end
    local build = state.project(root).build
    if build.status == "building" then
        return config.icons.building
    elseif build.status == "ok" then
        return config.icons.ok
    elseif build.status == "failed" then
        return config.icons.fail
    end
    return ""
end

return M
