-- lvim-tex: the zathura viewer.
--
-- The best-behaved external viewer for TeX work: it reloads the file by itself, takes a SyncTeX
-- position on the command line, and calls an editor back on ctrl-click — all through documented flags
-- (verified against the local binary's `--help`).
--
--   FORWARD   a running instance is addressed by PID: `--synctex-forward=<line>:<col>:<file>
--             --synctex-pid=<pid>` makes THAT window jump and flash the position. Without the pid a
--             second window would open instead, which is why forward search needs a launch we own.
--   INVERSE   `-x <command>` is accepted at LAUNCH only, so the callback is built there. zathura
--             substitutes `%{input}`, `%{line}` and `%{column}` itself and runs the result through a
--             shell — no shim script, and no `nvr`: the command is `nvim --server … --remote-expr …`.
--   RELOAD    automatic; zathura watches the file. Pushing a reload would be a second, racing one.
--
-- IT RAISES ITS WINDOW, and that turns out to be a SETTING rather than a fact. Every D-Bus command
-- zathura serves — `SynctexView` included, which is what `--synctex-forward` becomes — ends in a
-- `gtk_window_present` guarded by one runtime option, `dbus-raise-window` (zathurarc(5), default
-- true). So out of the box a forward search takes the keyboard, which is what makes zathura unusable
-- for the cursor-follow: the focus leaves the buffer every time the cursor settles.
--
-- That option is per INSTANCE and reachable at runtime, because `ExecuteCommand` is the one D-Bus
-- method exempt from the raise (`present_window = false` in zathura's own dispatch table). So the
-- window WE launched can be told `set dbus-raise-window false` without ever being presented, and the
-- user's zathurarc is left untouched. `viewer.zathura.forward = "quiet"` asks for exactly that. It is
-- opt-in rather than the default because it applies to EVERY sync, the explicit `,lv` included, and
-- whether that trade is wanted is not ours to assume.
--
---@module "lvim-tex.viewer.zathura"

local external = require("lvim-tex.viewer.external")
local synctex = require("lvim-tex.synctex")

local fn = vim.fn

local M = {}

M.name = "zathura"

--- Can the installed zathura load a document plugin? A whole-session fact (an install does not change
--- under a running editor) and the probe spawns a process, while `available` is asked on every viewer
--- resolution — so it is answered once and remembered.
---@type boolean?
local renders = nil

--- How long to keep asking a just-launched zathura to stop raising itself: its bus name appears a few
--- hundred ms after the process does, and the name is not activatable, so this is a poll or nothing.
--- User-visible (up to `retries × interval` of D-Bus attempts after every open), so it is config
--- like every other timeout here rather than a constant.
---@return integer retries, integer interval_ms
local function raise_policy()
    local spec = external.spec(M.name)
    local retries = tonumber(spec.raise_retries)
    local interval = tonumber(spec.raise_retry_ms)
    if not retries or retries < 0 then
        retries = 16
    end
    if not interval or interval < 0 then
        interval = 250
    end
    return math.floor(retries), math.floor(interval)
end

--- `forward = "raises"` is the OUT-OF-THE-BOX truth: `dbus-raise-window` defaults to true, so a sync
--- presents the window. `viewer.zathura.forward = "quiet"` overrides it (see the header) and the
--- viewer layer reads that override, so the cursor-follow starts driving zathura the moment it is set.
---@type { inverse: boolean, reload: "auto"|"push"|"none", status: boolean, forward: "quiet"|"raises"|false, position: boolean }
M.supports = { inverse = true, reload = "auto", status = false, forward = "raises", position = true }

--- Is zathura installed — and can it actually render a PDF?
---
--- zathura is a shell around per-format plugins, and the split matters here because of how it fails:
--- with no loadable PDF plugin it still starts, still takes the file, and still shows a window — an
--- EMPTY one. Nothing about that looks like a viewer problem from inside the editor, so it gets
--- blamed on the build or on this plugin. It is what a distribution upgrade of zathura without a
--- matching rebuild of its plugins leaves behind (zathura refuses a plugin whose ABI it does not
--- know), and `--version` is the cheapest invocation that loads them all and lists what survived.
---
--- The question is asked POSITIVELY — "is a pdf plugin loaded?" — and not by looking for refusals on
--- stderr, because those two are not the same question: cb / djvu / ps plugins from the same stale
--- build are refused by name too, and a zathura that renders PDFs perfectly well would be reported as
--- broken on their account. Only the PDF line decides.
---@return boolean ok, string? detail
function M.available()
    local ok, detail = external.available(M.name)
    if not ok then
        return ok, detail
    end
    if renders == nil then
        -- Each loaded plugin prints one "(plugin) <name> (<version>) (<path>)" line on stdout.
        local probe = vim.system({ external.spec(M.name).bin, "--version" }, { text = true }):wait()
        renders = (probe.stdout or ""):lower():find("%(plugin%)%s+[%w%-_]*pdf") ~= nil
    end
    if not renders then
        return true,
            "zathura has no PDF plugin loaded (it is built for another zathura version, or is not installed) — it opens an EMPTY window; rebuild/reinstall zathura-pdf-poppler or zathura-pdf-mupdf to match this zathura"
    end
    return true, nil
end

--- Tell the instance we just launched to stop presenting itself on D-Bus commands.
---
--- Retried rather than sent once: the bus name appears only when zathura has finished starting, which
--- is a few hundred milliseconds after the process exists, and there is nothing to wait ON — the name
--- is not activatable, so asking for it early simply fails. Bounded, and silent when it never arrives
--- (the user's window then behaves as zathura's own default says it should).
---@param pid integer
---@param tries integer
---@return nil
local function silence_raise(pid, tries)
    if tries <= 0 then
        return
    end
    vim.system({
        "gdbus",
        "call",
        "--session",
        "--dest",
        ("org.pwmt.zathura.PID-%d"):format(pid),
        "--object-path",
        "/org/pwmt/zathura",
        "--method",
        "org.pwmt.zathura.ExecuteCommand",
        "set dbus-raise-window false",
    }, { text = true }, function(result)
        if result.code == 0 then
            return
        end
        local _, interval = raise_policy()
        vim.schedule(function()
            vim.defer_fn(function()
                silence_raise(pid, tries - 1)
            end, interval)
        end)
    end)
end

--- Open the PDF, teaching the instance how to reach this editor back.
---@param ctx LvimTexViewCtx
---@return boolean ok, string? err
function M.open(ctx)
    local spec = external.spec(M.name)
    local argv = { spec.bin }
    local callback = synctex.editor_command({ file = "%{input}", line = "%{line}" })
    if callback then
        argv[#argv + 1] = "-x"
        argv[#argv + 1] = callback
    end
    external.extend(argv, spec.args)
    argv[#argv + 1] = ctx.pdf
    local ok, err = external.launch(M.name, ctx.pdf, argv, vim.fs.dirname(ctx.root))
    if ok and spec.forward == "quiet" and vim.fn.executable("gdbus") == 1 then
        local handle = external.handle(M.name, ctx.pdf)
        if handle and handle.pid then
            silence_raise(handle.pid, (raise_policy()))
        end
    end
    return ok, err
end

--- Is our zathura still showing this PDF?
---@param ctx LvimTexViewCtx
---@return boolean
function M.is_alive(ctx)
    return external.is_alive(M.name, ctx.pdf)
end

--- Highlight `boxes` in the instance we launched, the FIRST one as the active mark.
---
--- Why not `--synctex-forward` for this: zathura resolves the position itself and paints
--- `rect_list[0]` in `highlight-active-color`, but that list is `synctex`'s own reply order, which is
--- NOT document order — measured on a real paragraph, the first record was its second-to-last
--- typeset line. So the "you are here" mark landed on an arbitrary line of the paragraph and no
--- command line could change it (the column makes no difference: 1 and 200 return the same first
--- record).
---
--- `HighlightRects` is zathura's own method for handing it a list, and index 0 is what it makes
--- active — so ordering the boxes ourselves is the whole fix. Same-page boxes go in the primary list
--- (the tint), boxes on other pages in the secondary one; the page number is 0-BASED here, as
--- everywhere in zathura's interface.
--- `on_fail` is called when the CALL failed, not merely when the process could not be spawned: a
--- rejected argument or an instance that vanished must reach the fallback, and a fire-and-forget
--- send cannot tell the difference between "delivered" and "refused".
---@param pid integer
---@param boxes { page: integer, x: number, y: number, width: number, height: number }[]
---@param on_fail fun(): nil
---@return boolean attempted
local function highlight_boxes(pid, boxes, on_fail)
    if #boxes == 0 then
        return false
    end
    local page = boxes[1].page
    local primary, secondary = {}, {}
    for _, b in ipairs(boxes) do
        -- THE TUPLE IS (x1, x2, y1, y2), not the (x1, y1, x2, y2) every other rectangle API uses.
        -- zathura's own unpacking says so — `g_variant_iter_loop(iter, "(dddd)", &rect.x1, &rect.x2,
        -- &rect.y1, &rect.y2)` in `handle_highlight_rects` — and nothing in the interface XML hints
        -- at it. Sent in the ordinary order it does not fail: it draws, at coordinates made of the
        -- wrong fields, as one smeared block over the page.
        local x1, x2 = b.x, b.x + b.width
        local y1, y2 = b.y, b.y + b.height
        if b.page == page then
            primary[#primary + 1] = ("(%f,%f,%f,%f)"):format(x1, x2, y1, y2)
        else
            secondary[#secondary + 1] = ("(%d,%f,%f,%f,%f)"):format(b.page - 1, x1, x2, y1, y2)
        end
    end
    local ok = pcall(vim.system, {
        "gdbus",
        "call",
        "--session",
        "--dest",
        ("org.pwmt.zathura.PID-%d"):format(pid),
        "--object-path",
        "/org/pwmt/zathura",
        "--method",
        "org.pwmt.zathura.HighlightRects",
        tostring(page - 1),
        "@a(dddd) [" .. table.concat(primary, ",") .. "]",
        -- The type is spelled out because an EMPTY list has none of its own, and this one usually is
        -- empty: gdbus cannot infer `a(udddd)` from `[]` and refuses the call.
        "@a(udddd) [" .. table.concat(secondary, ",") .. "]",
    }, { text = true }, function(result)
        if result.code ~= 0 then
            vim.schedule(on_fail)
        end
    end)
    if not ok then
        vim.schedule(on_fail)
    end
    return true
end

--- Jump the OPEN window to a position. Addressed by pid, so the instance we launched moves instead of
--- a new one appearing; a viewer we did not launch has no pid we could name.
---@param ctx LvimTexViewCtx
---@param target { line: integer, col: integer, file: string }
---@return boolean
function M.forward(ctx, target)
    if not M.is_alive(ctx) then
        return false
    end
    local spec = external.spec(M.name)
    local handle = external.handle(M.name, ctx.pdf)
    -- Preferred path: resolve the boxes here and hand zathura an ORDERED list, so the active mark
    -- lands on the line the position actually begins at (see `highlight_boxes`). The command line
    -- below stays as the answer for a zathura we cannot address on the bus — no gdbus, or an
    -- instance that is not ours — and for a position `synctex` could not resolve into boxes at all.
    if handle and handle.pid and fn.executable("gdbus") == 1 then
        --- What zathura would have done by itself, for when the bus path does not work out.
        ---@return nil
        local function by_command_line()
            external.tell({
                spec.bin,
                ("--synctex-forward=%d:%d:%s"):format(target.line, math.max(1, target.col), target.file),
                ("--synctex-pid=%d"):format(handle.pid),
                ctx.pdf,
            }, vim.fs.dirname(ctx.root))
        end
        synctex.view_boxes(ctx.root, target.file, target.line, target.col or 1, function(boxes)
            if not highlight_boxes(handle.pid, boxes, by_command_line) then
                by_command_line()
            end
        end)
        return true
    end
    local argv = {
        spec.bin,
        ("--synctex-forward=%d:%d:%s"):format(target.line, math.max(1, target.col), target.file),
    }
    if handle and handle.pid then
        argv[#argv + 1] = ("--synctex-pid=%d"):format(handle.pid)
    end
    argv[#argv + 1] = ctx.pdf
    return external.tell(argv, vim.fs.dirname(ctx.root))
end

--- Which page is the reader on? The coarse half of the two-way link.
---
--- zathura publishes `pagenumber` as a readable D-Bus property and emits NO signal when it changes
--- (its interface has exactly one signal, for ctrl-click), so this is a poll or nothing — the layer
--- owns the timer, this only answers.
---
--- THE PROPERTY IS 0-BASED. Verified two ways: in zathura's source the getter returns
--- `zathura_document_get_current_page_number`, which pairs with `GotoPage`'s 0-based bound; and live
--- — a read of 65 while the window showed the 66th page. SyncTeX pages are 1-based, so the answer is
--- shifted here, at the one place that knows whose convention it is.
---@param ctx LvimTexViewCtx
---@param cb fun(page: integer?): nil
---@return nil
function M.position(ctx, cb)
    if fn.executable("gdbus") ~= 1 then
        return cb(nil)
    end
    local handle = external.handle(M.name, ctx.pdf)
    if not handle or not handle.pid then
        return cb(nil)
    end
    local ok = pcall(vim.system, {
        "gdbus",
        "call",
        "--session",
        "--dest",
        ("org.pwmt.zathura.PID-%d"):format(handle.pid),
        "--object-path",
        "/org/pwmt/zathura",
        "--method",
        "org.freedesktop.DBus.Properties.Get",
        "org.pwmt.zathura",
        "pagenumber",
    }, { text = true }, function(result)
        local n = result.code == 0 and tostring(result.stdout or ""):match("uint32%s+(%d+)") or nil
        vim.schedule(function()
            cb(n and (tonumber(n) + 1) or nil)
        end)
    end)
    if not ok then
        cb(nil)
    end
end

--- Close our window.
---@param ctx LvimTexViewCtx
---@return nil
function M.close(ctx)
    external.close(M.name, ctx.pdf)
end

return M
