-- lvim-tex: the shared machinery every EXTERNAL viewer needs.
--
-- Each external viewer differs only in its argv: how it is launched on a file, how it is told to jump
-- to a position, and how it is taught to call back into the editor. Everything AROUND that is the
-- same for all of them, and duplicating it seven times is how the seventh ends up subtly different:
--
--   PROCESS OWNERSHIP — one child per PDF, detached (it must outlive a `:LvimTex reload`), tracked so
--     `is_alive` is an answer about a real process rather than a guess, and reaped when it exits so a
--     viewer the user closed does not look open forever.
--   NOT KILLED ON EXIT — a viewer the user opened is theirs. `close` is explicit.
--   INVERSE SEARCH — the callback string is built once, by `synctex.editor_command`, with each
--     viewer's own placeholders substituted; a viewer that only accepts it at LAUNCH time is why the
--     command is assembled in `open` rather than when inverse search is first used.
--
-- The one thing this module deliberately does NOT do is decide whether a viewer supports something.
-- That is declared per module, as data, because it is a fact about the viewer.
--
---@module "lvim-tex.viewer.external"

local config = require("lvim-tex.config")

local fn = vim.fn

local M = {}

--- Running children, per viewer name and PDF path: `procs[name][pdf] = vim.SystemObj`.
---@type table<string, table<string, table>>
local procs = {}

--- The spec table for a viewer name, from the live config.
---@param name string
---@return table
function M.spec(name)
    return config.viewer[name] or {}
end

--- Is the viewer's binary present?
---@param name string
---@param bin string?
---@return boolean ok, string? detail
function M.available(name, bin)
    bin = bin or M.spec(name).bin
    if not bin or bin == "" then
        return false, ("viewer.%s.bin is not set"):format(name)
    end
    if fn.executable(bin) ~= 1 then
        return false, ("%s is not installed"):format(bin)
    end
    return true, nil
end

--- Launch `argv` as this viewer's child for `pdf`.
---
--- Detached, because the viewer is a window the user works in and must not die with a reloaded module
--- or a closed job. The exit callback drops the entry, which is what keeps `is_alive` honest after the
--- user closes the window themselves.
---@param name string
---@param pdf string
---@param argv string[]
---@param cwd string?
---@return boolean ok, string? err
function M.launch(name, pdf, argv, cwd)
    local ok, handle = pcall(vim.system, argv, { cwd = cwd, detach = true }, function()
        vim.schedule(function()
            if procs[name] then
                procs[name][pdf] = nil
            end
        end)
    end)
    if not ok then
        return false, ("could not launch %s: %s"):format(argv[1] or name, tostring(handle))
    end
    procs[name] = procs[name] or {}
    procs[name][pdf] = handle
    return true, nil
end

--- Run a one-shot argv that talks to an ALREADY OPEN viewer (a forward-search request to a
--- single-instance viewer). Nothing is tracked: it is a message, not a window.
---@param argv string[]
---@param cwd string?
---@return boolean
function M.tell(argv, cwd)
    local ok = pcall(vim.system, argv, { cwd = cwd, detach = true })
    return ok
end

--- Is a child of this viewer still showing `pdf`?
---@param name string
---@param pdf string
---@return boolean
function M.is_alive(name, pdf)
    local handle = procs[name] and procs[name][pdf]
    if not handle then
        return false
    end
    -- `is_closing` is the only cheap liveness question a SystemObj answers; the exit callback above
    -- removes the entry, so a stale one only exists for the instant between exit and schedule.
    local alive = pcall(function()
        return handle.pid
    end)
    return alive == true
end

--- The tracked child for `pdf`, or nil. A viewer that addresses its own instance (zathura's
--- `--synctex-pid`) needs the pid, which is the one detail of the handle worth exposing.
---@param name string
---@param pdf string
---@return table?
function M.handle(name, pdf)
    return procs[name] and procs[name][pdf] or nil
end

--- Close this viewer's window for `pdf` — an explicit request, never automatic.
---@param name string
---@param pdf string
---@return nil
function M.close(name, pdf)
    local handle = procs[name] and procs[name][pdf]
    if not handle then
        return
    end
    pcall(function()
        handle:kill(15)
    end)
    procs[name][pdf] = nil
end

--- Every argument of `args`, with `%s`-style placeholders left alone: a user's argv is passed through
--- verbatim, which is why it is a LIST and never a shell string.
---@param argv string[]
---@param args string[]?
---@return string[]
function M.extend(argv, args)
    for _, arg in ipairs(args or {}) do
        argv[#argv + 1] = arg
    end
    return argv
end

return M
