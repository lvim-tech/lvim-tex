-- lvim-tex: the DEFAULT viewer — lvim-preview's pdf.js page.
--
-- Every other viewer this plugin can drive has to be installed, configured, and taught how to talk back
-- to the editor. This one is already in the ecosystem, works on every platform, and is the only viewer
-- that can show what the BUILD is doing: lvim-preview's artifact seam exists for exactly this producer
-- shape — a file some external toolchain writes, where only the producer knows when it became coherent.
--
-- So the wiring is small and all of it is the seam's own vocabulary:
--
--   register  once per project, BEFORE the first build — the page can then be opened immediately and
--             says "building" over an empty view instead of 404-ing on a PDF that does not exist yet.
--   status    "building" raises a spinner over the LAST GOOD render (nothing is refetched, so nothing
--             flickers), "error" a strip, "ok" clears it. Full diagnostics stay in the editor.
--   reload    the explicit "this file is new and complete" signal. We do NOT use the artifact's own
--             `watch = true`: a build writes the PDF several times across its reruns, and a filesystem
--             watcher would refetch half-written intermediates. The build's success path is the only
--             honest signal, so `supports.reload = "push"`.
--
-- How the PAGE behaves — position restore across a reload, lazy rasterisation, the forward-search
-- highlight duration — is lvim-preview's configuration and stays there. This plugin deliberately ships
-- no mirror of those options: a second switch for one behaviour has to be kept in sync forever and the
-- loser is whichever plugin wrote last. One owner (see findings `G11`).
--
-- Inverse search (ctrl-click in the page) arrives through the SAME seam, as the artifact's own
-- `on_message`, and is doubly gated: lvim-preview's `artifact.allow_client_messages` must be on AND
-- this handler must exist. The first half is the user's setting in lvim-preview's config — health
-- prints the exact line — because turning another plugin's gate on from here would silently override
-- a decision they made there.
--
-- The artifact id is `lvim-tex:<root>` — stable across restarts, so re-registering after a reload keeps
-- the URL and every already-open tab valid.
--
---@module "lvim-tex.viewer.preview"

local config = require("lvim-tex.config")
local synctex = require("lvim-tex.synctex")

local fs = vim.fs
local fn = vim.fn

local M = {}

M.name = "preview"

--- `forward = "quiet"`: the page is a websocket message to a browser tab that is already open —
--- nothing is presented and no window manager is involved, so the cursor-follow may drive it.
---@type { inverse: boolean, reload: "auto"|"push"|"none", status: boolean, forward: "quiet"|"raises"|false }
M.supports = { inverse = true, reload = "push", status = true, forward = "quiet" }

---@type "live"|"docs"|"platform"|"experimental"
M.verified = "live"

--- The lvim-preview module, or nil when it is not installed.
---@return table?
local function preview()
    local ok, mod = pcall(require, "lvim-preview")
    return ok and mod or nil
end

--- The artifact id for a project.
---@param ctx LvimTexViewCtx
---@return string
local function id_of(ctx)
    return "lvim-tex:" .. ctx.root
end

--- Is this viewer usable?
---@return boolean ok, string? detail
function M.available()
    if not preview() then
        return false, "lvim-preview is not installed"
    end
    return true, nil
end

--- The handle for this project's artifact, or nil when it is not registered on a running server.
---@param ctx LvimTexViewCtx
---@return table?
local function handle(ctx)
    local mod = preview()
    if not mod or not mod.is_running() then
        return nil
    end
    return mod.artifact(id_of(ctx))
end

--- Register the PDF and open its page in the browser.
---
--- Registration is idempotent by id: re-opening an already-registered project re-registers it (keeping
--- the URL and the generation) and opens a fresh tab, which is what a user asking for the viewer again
--- after closing the tab means.
---@param ctx LvimTexViewCtx
---@param opts { no_browser: boolean? }?  `no_browser` re-registers without opening a tab (retarget)
---@return boolean ok, string? err
function M.open(ctx, opts)
    local mod = preview()
    if not mod then
        return false, "lvim-preview is not installed"
    end
    local h, err = mod.register_artifact({
        id = id_of(ctx),
        path = ctx.pdf,
        viewer = "pdf",
        title = ("%s · %s"):format(fn.fnamemodify(ctx.pdf, ":t"), fs.basename(fs.dirname(ctx.root))),
        watch = false,
        -- The two shapes this producer understands, declared so the FRAMEWORK rejects everything
        -- else before it reaches the handler below. The page is a browser and its frames are
        -- untrusted; naming the contract is cheaper than defending against it here.
        accepts = { "synctex_edit", "synctex_scroll" },
        -- INVERSE SEARCH. The page sends exactly one kind of frame, on ctrl-click, and only when
        -- lvim-preview's own `artifact.allow_client_messages` gate is open — that gate is the USER's
        -- to set, in lvim-preview's config, and health prints the line rather than this plugin
        -- reaching into another plugin's settings. Supplying the handler is our half of it.
        --
        -- The page sends TWO shapes now, and they mean opposite things. `synctex_edit` is a
        -- ctrl-click: "take me to the source of THIS" — a jump, cursor and all. `synctex_scroll` is
        -- the reader having scrolled: "the source of what I am now looking at" — a follow, which
        -- moves the view and never the cursor, and which the link's ownership window can drop as an
        -- echo of our own forward search. One handler, because the gate and the artifact are one.
        on_message = config.synctex.inverse and function(msg)
            if type(msg) ~= "table" then
                return
            end
            local page = math.floor(tonumber(msg.page) or 0)
            if page <= 0 then
                return
            end
            if msg.type == "synctex_edit" then
                synctex.inverse(ctx.pdf, page, tonumber(msg.x) or 0, tonumber(msg.y) or 0)
            elseif msg.type == "synctex_scroll" then
                synctex.follow_back(ctx.pdf, page, tonumber(msg.x) or 0, tonumber(msg.y) or 0)
            end
        end or nil,
    })
    if not h then
        return false, err or "could not register the artifact"
    end
    if not (opts and opts.no_browser) then
        mod.open(id_of(ctx))
    end
    return true, nil
end

--- Serve a DIFFERENT file on the same page. Re-registration is keyed on the artifact id, so the slug —
--- and therefore the URL of every open tab — survives; only the path behind it changes. No browser is
--- launched: the tab the user already has is the one that must follow, and `reload` makes it refetch.
---@param ctx LvimTexViewCtx
---@return nil
function M.retarget(ctx)
    local mod = preview()
    if not mod then
        return
    end
    M.open(ctx, { no_browser = true })
    M.reload(ctx)
end

--- Is the page being served for this project?
---
--- "Alive" is what is OBSERVABLE: the artifact is registered on a running server. Whether a browser tab
--- is actually displaying it cannot be known from here — and does not need to be, since re-opening the
--- same URL is what the user does either way.
---@param ctx LvimTexViewCtx
---@return boolean
function M.is_alive(ctx)
    return handle(ctx) ~= nil
end

--- Tell the page the file is new and complete.
---@param ctx LvimTexViewCtx
---@return nil
function M.reload(ctx)
    local h = handle(ctx)
    if h then
        h:reload()
    end
end

--- Show the build state over the render.
---@param ctx LvimTexViewCtx
---@param st "building"|"ok"|"error"
---@param message string?
---@return nil
function M.status(ctx, st, message)
    local h = handle(ctx)
    if h then
        h:status(st, message)
    end
end

--- Forward search: scroll the page to a PDF point and flash it. The coordinate contract is
--- lvim-preview's (`page` 1-based, `x`/`y` in points from the page's top-left) and is exactly what
--- `synctex view` reports, so the viewer layer hands its result over unchanged.
---@param ctx LvimTexViewCtx
---@param target { page: integer, x: number, y: number, width: number?, height: number? }
---@return boolean
function M.forward(ctx, target)
    local h = handle(ctx)
    if not h then
        return false
    end
    -- `width`/`height` are the typeset BOX (see lvim-tex.synctex): passing them makes the band cover
    -- the line instead of the page-wide 14pt default the page falls back to.
    return h:synctex({
        page = target.page,
        x = target.x,
        y = target.y,
        width = target.width,
        height = target.height,
    }) == true
end

--- Unregister the artifact. lvim-preview stops its server when nothing else is being served.
---@param ctx LvimTexViewCtx
---@return nil
function M.close(ctx)
    local h = handle(ctx)
    if h then
        h:close()
    end
end

return M
