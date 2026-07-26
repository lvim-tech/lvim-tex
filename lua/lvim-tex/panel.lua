-- lvim-tex: the BUILD PANEL — what the last build did, and why it says what it says.
--
-- `:LvimTex info` used to be a notify blob. A build has more to show than fits in one: the project it
-- resolved, the builder and engine actually used, the watch set the continuous loop is keyed on, the
-- diagnostics grouped by severity — and, the part no other view offers, WHICH LOG RULE produced each
-- entry. A wrong verdict on a log line is otherwise unexplainable; naming the rule makes it a one-line
-- fix in `diagnostics.rules`.
--
-- Built on the canonical `lvim-ui.tabs` menu surface (the how-build-panels chassis), so it is centered,
-- themed, cursor-managed and closed like every other panel in the ecosystem. Two tabs:
--
--   Summary — the project + build facts, then the diagnostics, each row jumping to its file:line.
--   Output  — the builder's raw stdout/stderr tail (`config.output_lines`), for when the parser has
--             nothing to say but the engine clearly did.
--
-- Read-only: nothing here mutates a build. The panel re-reads state on open; a build finishing while it
-- is open refreshes it through the same `LvimTexBuildDone` event every other consumer uses.
--
---@module "lvim-tex.panel"

local api = vim.api
local config = require("lvim-tex.config")
local state = require("lvim-tex.state")
local root_mod = require("lvim-tex.root")
local viewer = require("lvim-tex.viewer")
local ui = require("lvim-ui")

local M = {}

---@type table?  the live handle, so a second open focuses instead of stacking
local handle = nil

--- Severity → its label, highlight and GLYPH, in report order. The glyph matters: a run of rows all
--- wearing the error mark reads as "everything is broken" when most of them are hints.
---@type { [1]: integer, [2]: string, [3]: string, [4]: string }[]
local SEVERITIES = {
    { vim.diagnostic.severity.ERROR, "error", "DiagnosticError", "fail" },
    { vim.diagnostic.severity.WARN, "warning", "DiagnosticWarn", "warn" },
    { vim.diagnostic.severity.INFO, "info", "DiagnosticInfo", "info" },
    { vim.diagnostic.severity.HINT, "hint", "DiagnosticHint", "hint" },
}

--- A read-only fact row: a dim label column and its value.
---@param name string
---@param label string
---@param value string
---@return table
local function fact(name, label, value)
    return {
        type = "action",
        name = name,
        flat = true,
        tight = true,
        icon = "",
        label = ("  %-10s %s"):format(label, value),
        text_hl = "LvimUiPathName",
        run = function() end,
    }
end

--- A diagnostic row: severity glyph + `file:line` + the message, with the RULE that produced it. `<CR>`
--- jumps to the position, which is why the rule id sits at the end rather than in front of the message.
---@param item LvimTexItem
---@param hl string
---@param glyph string
---@return table
local function diag_row(item, hl, glyph)
    local where = ("%s:%d"):format(vim.fs.basename(item.file), item.lnum)
    return {
        type = "action",
        name = ("diag:%s:%d"):format(item.file, item.lnum),
        flat = true,
        tight = true,
        icon = " " .. glyph .. " ",
        icon_hl = hl,
        label = ("%-22s %s   [%s]"):format(where, item.message, item.rule),
        text_hl = hl,
        run = function()
            M.close()
            vim.schedule(function()
                vim.cmd.edit(vim.fn.fnameescape(item.file))
                pcall(api.nvim_win_set_cursor, 0, { math.max(1, item.lnum), math.max(0, item.col - 1) })
            end)
        end,
    }
end

--- What the viewer row says: the one showing this project, or the one that WOULD be used — a panel
--- that only ever said "none" while a viewer was merely unopened would answer the wrong question.
---@param root string
---@return string
local function viewer_state(root)
    if not config.viewer.enabled then
        return "disabled"
    end
    if viewer.is_alive(root) then
        return ("%s · open"):format(state.project(root).viewer)
    end
    local mod, err = viewer.resolve()
    return mod and ("%s · not open"):format(mod.name) or (err or "none available")
end

--- The Summary tab's rows for `root`.
---@param root string
---@return table[]
local function summary_rows(root)
    local project = state.project(root)
    local b = project.build
    local engine = root_mod.engine(project.target)
    local watch = root_mod.watch(root, project.target, root_mod.out_dir(root))
    local duration = (b.started and b.finished) and math.floor((b.finished - b.started) / 1e6) or nil
    local pdf = root_mod.pdf(root, project.target)

    local rows = {
        fact("f:root", "root", vim.fn.fnamemodify(root, ":~")),
        fact("f:target", "target", vim.fn.fnamemodify(project.target, ":~")),
        fact(
            "f:builder",
            "builder",
            (root_mod.program(project.target) or config.builder) .. (engine and (" (" .. engine .. ")") or "")
        ),
        fact("f:out", "out dir", vim.fn.fnamemodify(root_mod.out_dir(root), ":~")),
        fact(
            "f:pdf",
            "pdf",
            vim.fn.fnamemodify(pdf, ":~") .. (vim.fn.filereadable(pdf) == 1 and "" or "  (not built)")
        ),
        fact("f:viewer", "viewer", viewer_state(root)),
        fact(
            "f:state",
            "state",
            b.status
                .. (b.code and (" · exit %d"):format(b.code) or "")
                .. (duration and (" · %dms"):format(duration) or "")
        ),
        fact(
            "f:loop",
            "continuous",
            (b.continuous and "armed" or "off") .. (config.continuous.enabled and "" or " (disabled in config)")
        ),
        fact("f:watch", "watching", ("%d file%s"):format(#watch, #watch == 1 and "" or "s")),
    }

    local diags = project.diags or {}
    if #diags == 0 then
        rows[#rows + 1] = {
            type = "spacer",
            name = "clean",
            label = ("  %s no diagnostics from the last build"):format(config.icons.ok),
            hl = { inactive = "DiagnosticOk" },
        }
        return rows
    end

    -- Grouped by severity so the errors are not buried under a run of hints.
    for _, sev in ipairs(SEVERITIES) do
        local group = {}
        for _, item in ipairs(diags) do
            if item.severity == sev[1] then
                group[#group + 1] = diag_row(item, sev[3], config.icons[sev[4]] or config.icons.fail)
            end
        end
        if #group > 0 then
            rows[#rows + 1] = ui.section({
                name = "sev:" .. sev[2],
                icon = " ",
                box_hl = sev[3],
                label = ("%d %s%s"):format(#group, sev[2], #group == 1 and "" or "s"),
                accent = (sev[2] == "error" and "red") or (sev[2] == "warning" and "yellow") or "blue",
                count = #group,
                expanded = sev[1] <= vim.diagnostic.severity.WARN, -- errors and warnings open, the rest folded
                children = group,
            })
        end
    end
    return rows
end

--- The Output tab's rows — the builder's raw tail, one row per line.
---@param root string
---@return table[]
local function output_rows(root)
    local out = state.project(root).build.output or {}
    if #out == 0 then
        return {
            {
                type = "spacer",
                name = "no-output",
                label = "  the builder produced no output yet",
                hl = { inactive = "LvimUiPathName" },
            },
        }
    end
    local rows = {}
    for i, line in ipairs(out) do
        rows[#rows + 1] = {
            type = "action",
            name = "o" .. i,
            flat = true,
            tight = true,
            icon = "",
            label = line == "" and " " or line,
            text_hl = "LvimUiPathName",
            run = function() end,
        }
    end
    return rows
end

--- The LIVE handle, or nil. Every caller goes through this rather than reading `handle` directly: the
--- module-level value is nil-able and a closure that captured it cannot know whether the panel has since
--- closed, which is exactly the check a stale refresh must make.
---@return table?
local function live()
    if handle ~= nil and handle.valid ~= nil and handle.valid() then
        return handle
    end
    return nil
end

--- Is the panel open?
---@return boolean
function M.is_open()
    return live() ~= nil
end

--- Close it (no-op when closed).
---@return nil
function M.close()
    local h = live()
    if h then
        h.close()
    end
    handle = nil
end

--- The TeX buffer this panel should report on.
---
--- Deliberately NOT just "the current buffer": the panel is most often opened right after a failed
--- build, when the quickfix window has taken focus — resolving the project from THAT buffer produced a
--- root called `quickfix-4`. When the buffer handed in is not a TeX buffer, fall back the way health
--- does: the alternate buffer, then any visible window, then any loaded buffer.
---@param buf integer?
---@return integer?
local function tex_buffer(buf)
    local function is_tex(b)
        return b and b > 0 and api.nvim_buf_is_loaded(b) and vim.tbl_contains(config.filetypes, vim.bo[b].filetype)
    end
    local given = (buf == nil or buf == 0) and api.nvim_get_current_buf() or buf
    if is_tex(given) then
        return given
    end
    local alternate = vim.fn.bufnr("#")
    if is_tex(alternate) then
        return alternate
    end
    for _, win in ipairs(api.nvim_list_wins()) do
        local b = api.nvim_win_get_buf(win)
        if is_tex(b) then
            return b
        end
    end
    for _, b in ipairs(api.nvim_list_bufs()) do
        if is_tex(b) then
            return b
        end
    end
    return nil
end

--- Open the build panel for the project `buf` belongs to.
---@param buf integer?
---@return nil
function M.open(buf)
    local target_buf = tex_buffer(buf)
    if not target_buf then
        vim.notify("lvim-tex: open a TeX buffer to see its build", vim.log.levels.WARN)
        return
    end
    local root = root_mod.of(target_buf)
    if not root then
        vim.notify("lvim-tex: this buffer has no file on disk", vim.log.levels.WARN)
        return
    end
    if M.is_open() then
        M.close()
    end

    local tabs = {
        { label = "Summary", icon = config.icons.section, menu = true, rows = summary_rows(root) },
        { label = "Output", icon = config.icons.doc, menu = true, rows = output_rows(root) },
    }

    handle = ui.tabs({
        title = { icon = config.icons.building, text = ("lvim-tex · %s"):format(vim.fs.basename(root)) },
        title_pos = "center",
        tabs = tabs,
        layout = config.panel and config.panel.layout or "float",
        cursorline_hl = "LvimUiCursorLine",
        close_keys = { "q", "<Esc>" },
        callback = function()
            handle = nil
        end,
        on_open = function()
            -- A build finishing while the panel is up refreshes it in place, through the SAME event
            -- every other consumer listens to — no polling, and no second source of truth.
            api.nvim_create_autocmd("User", {
                pattern = "LvimTexBuildDone",
                desc = "lvim-tex: refresh the build panel",
                callback = function()
                    local h = live()
                    if not h then
                        return true -- the panel is gone: drop the autocmd with it
                    end
                    tabs[1].rows = summary_rows(root)
                    tabs[2].rows = output_rows(root)
                    local idx = h.cursor_index and h.cursor_index() or 1
                    h.recalc()
                    if h.focus_index then
                        h.focus_index(idx)
                    end
                end,
            })
        end,
    })
end

return M
