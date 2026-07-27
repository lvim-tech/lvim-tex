-- lvim-tex: SYNCTEX — the two-way map between a place in the source and a place in the PDF.
--
-- TeX throws away the correspondence between what you wrote and what was typeset; `-synctex=1` makes
-- the engine record it in `<jobname>.synctex.gz`, and the `synctex` utility is the only thing that
-- reads that format. Both directions therefore go through it, and this module is the ONE place that
-- knows its command line and its output shape:
--
--   FORWARD   `synctex view -i <line>:<col>:<file> -o <pdf>`   → Page / x / y
--   INVERSE   `synctex edit -o <page>:<x>:<y>:<pdf>`           → Input / Line / Column
--
-- COORDINATES. `x` / `y` are PDF points measured from the TOP-LEFT of the page and the page number is
-- 1-based — exactly the contract lvim-preview's `Handle:synctex` documents, so a forward result is
-- handed over unchanged. Nothing here converts anything.
--
-- PATHS. `synctex` matches the name the ENGINE recorded, and it only reliably resolves ABSOLUTE ones
-- (`./main.tex` gives "No tag for ./main.tex" against a log that recorded it from another directory).
-- Every path is therefore made absolute before it is handed over, and the child runs in the root's
-- directory so a relative `Output:` in the reply still resolves.
--
-- HOW A VIEWER REACHES BACK. An external viewer runs a COMMAND when you ctrl-click, so the editor
-- must be addressable from a shell. Neovim already is: `v:servername` names its socket, and
-- `nvim --server <socket> --remote-expr <expr>` evaluates in the running instance. There is no shim
-- script on disk and no `nvr` dependency — `M.editor_command` builds that string, with each viewer's
-- own placeholders substituted in. Our default viewer needs none of it: it is a page on lvim-preview's
-- own websocket, which delivers the click straight to `M.inverse`.
--
---@module "lvim-tex.synctex"

local config = require("lvim-tex.config")
local root_mod = require("lvim-tex.root")
local state = require("lvim-tex.state")

local api = vim.api
local fn = vim.fn
local fs = vim.fs

local M = {}

--- Notify, gated by `config.notify`.
---@param msg string
---@param level integer?
---@return nil
local function notify(msg, level)
    if config.notify then
        vim.notify("lvim-tex: " .. msg, level or vim.log.levels.INFO)
    end
end

--- Is the `synctex` utility usable?
---@return boolean ok, string? detail
function M.available()
    local bin = config.synctex.bin
    if fn.executable(bin) ~= 1 then
        return false, ("%s is not on PATH — it ships with every TeX distribution"):format(bin)
    end
    return true, nil
end

--- Parse a `synctex` reply into its `Key:value` fields. The utility prints a banner line, a
--- `SyncTeX result begin` / `end` frame and one field per line; anything outside that shape is noise
--- from a warning, which is why a missing field is nil rather than an error.
---@param out string
---@return table<string, string>
local function fields(out)
    local map = {}
    for line in (out or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^(%a+):%s*(.*)$")
        if key and not map[key] then
            map[key] = value
        end
    end
    return map
end

--- Run `synctex` with `args` in `cwd` and hand the parsed fields to `done`.
---@param args string[]
---@param cwd string
---@param done fun(f: table<string, string>, code: integer, raw: string): nil
---@return nil
local function run(args, cwd, done)
    local argv = { config.synctex.bin }
    vim.list_extend(argv, args)
    -- `available()` only asks whether the NAME resolves; the spawn itself can still fail — an
    -- unreadable cwd, a binary replaced mid-session, a process limit. This runs from cursor and
    -- scroll autocmds, where an uncaught error surfaces as a Neovim error message for something the
    -- user never asked for. A failure is delivered as an empty reply instead, which every caller
    -- already handles as "no answer".
    local ok = pcall(vim.system, argv, { cwd = cwd, text = true }, function(result)
        local text = (result.stdout or "") .. (result.stderr or "")
        vim.schedule(function()
            done(fields(text), result.code, text)
        end)
    end)
    if not ok then
        vim.schedule(function()
            done({}, -1, "")
        end)
    end
end

--- Every RECORD of a `view` reply, in document order.
---
--- `fields` collapses the whole reply into one flat map, first occurrence winning, and for `edit`
--- that is right — it answers once. `view` does NOT: it prints one `Page:/x:/y:/h:/v:/W:/H:` group
--- per box it can place for that line, and taking the first is how a page-breaking paragraph gets
--- read as a degenerate one. Measured on a real book: line 46 prints ~24 records of which the FIRST
--- is `Page:1 v:141.78 H:0` — while the very next records are the same line's REAL boxes
--- (`Page:1 v:713.44 H:13.5`). Reading only the first turned a paragraph that starts at the foot of
--- page 1 into either a zero-height box or, after the degenerate-record retry, a position a full
--- page late.
--- Public for the same reason as `resolve_input`: the reply's SHAPE is this module's contract, and
--- the multi-record case is exactly the one that regressed silently.
---@param out string
---@return table<string, number>[]
function M.records(out)
    local list = {}
    local cur = nil
    for line in (out or ""):gmatch("[^\r\n]+") do
        local key, value = line:match("^(%a+):%s*(.*)$")
        if key == "Page" then
            cur = { Page = tonumber(value) }
            list[#list + 1] = cur
        elseif key and cur then
            local n = tonumber(value)
            if n and cur[key] == nil then
                cur[key] = n
            end
        end
    end
    return list
end

--- The record to answer with: the first with a real extent, else the first of all.
---
--- Records come in document order, so the first `H > 0` box is where the line's typeset material
--- BEGINS — which is what a forward search should land on. A reply in which every record is
--- degenerate is a line the engine placed without extent at all; the caller decides what to do then.
---@param list table<string, number>[]
---@return table<string, number>?, boolean all_degenerate
function M.best_record(list)
    for _, r in ipairs(list) do
        if (r.H or 0) > 0 and (r.W or 0) > 0 then
            return r, false
        end
    end
    return list[1], #list > 0
end

--- A path as `synctex` reported it, made absolute.
---
--- The utility answers with the name the ENGINE recorded, and that name may be relative — to the
--- directory the child ran in, which is the PDF's, not Neovim's. Every consumer here (the jump, the
--- source placement, the verification re-query) would otherwise resolve it against whatever
--- directory the user happens to be in: a missing file, or worse, a same-named file in another
--- project. The module's own path contract already says resolution depends on the build directory;
--- this is where that is honoured.
--- Public because it is part of this module's stated contract — it is the ONE place that knows how a
--- `synctex` reply's paths resolve — and because a contract with no test is a claim.
---@param path string
---@param cwd string   the directory the `synctex` child ran in
---@return string
function M.resolve_input(path, cwd)
    if path == "" then
        return path
    end
    local joined = fs.joinpath and not vim.startswith(path, "/") and fs.joinpath(cwd, path) or path
    if vim.startswith(path, "/") then
        joined = path
    end
    return fs.normalize(fn.fnamemodify(joined, ":p"))
end

--- The lines of `file` — from the LOADED buffer when there is one, so an unsaved edit counts.
---@param file string
---@return string[]
local function lines_of(file)
    local buf = fn.bufnr(file)
    if buf ~= -1 and api.nvim_buf_is_loaded(buf) then
        return api.nvim_buf_get_lines(buf, 0, -1, false)
    end
    local ok, lines = pcall(fn.readfile, file)
    return (ok and type(lines) == "table") and lines or {}
end

--- The nearest line that puts something ON THE PAGE, starting from `lnum`.
---
--- A blank line, or a line holding nothing but a comment, is typeset as NOTHING, so `synctex` has no
--- record for it and answers with the nearest node it does know — which can be an unrelated place
--- pages away (measured: a blank line between two paragraphs of a real book resolved to the chapter
--- heading on the PREVIOUS page). Asking about such a line at all is the mistake; the honest target is
--- the text around it.
---
--- Downwards first, because a blank line is most often the one you are about to write in; upwards only
--- when there is nothing below.
---@param file string
---@param lnum integer
---@return integer
local function typeset_line(file, lnum)
    local lines = lines_of(file)
    if #lines == 0 then
        return lnum
    end
    --- Does this line put nothing on the page?
    ---@param i integer
    ---@return boolean
    local function empty(i)
        local line = lines[i]
        return line == nil or line:match("^%s*$") ~= nil or line:match("^%s*%%") ~= nil
    end
    if not empty(lnum) then
        return lnum
    end
    for i = lnum + 1, #lines do
        if not empty(i) then
            return i
        end
    end
    for i = lnum - 1, 1, -1 do
        if not empty(i) then
            return i
        end
    end
    return lnum
end

--- FORWARD: where in the PDF does `file:line:col` end up?
---
--- `synctex` answers for the position it can place, which is usually the start of the paragraph the
--- line belongs to — that is the granularity the format records, not a rounding error here.
---@param root string
---@param file string   absolute path of the source file
---@param lnum integer   1-based
---@param col integer    1-based
---@param done fun(target: { page: integer, x: number, y: number, width: number?, height: number?, point: { x: number, y: number } }?, err: string?): nil
---@return nil
function M.view(root, file, lnum, col, done)
    local ok, why = M.available()
    if not ok then
        return done(nil, why)
    end
    local pdf = root_mod.pdf(root, state.project(root).target)
    if fn.filereadable(pdf) ~= 1 then
        return done(nil, "no PDF yet — build first")
    end

    --- Ask about `line`, walking on when it is typeset nowhere usable.
    ---
    --- The answer is the FIRST BOX IN DOCUMENT ORDER, which is what `view_boxes` exists to produce —
    --- `synctex`'s reply is not ordered, so "the first record" is an arbitrary line of the paragraph,
    --- and taking it put the mark on the page number at the foot of the previous page or on an
    --- italic phrase in the middle. Same list, same order, same first entry as the one handed to a
    --- viewer that takes rectangles, so the two never disagree about where the position is.
    ---@param line integer
    ---@param tries integer
    ---@return nil
    local function ask_view(line, tries)
        M.view_boxes(root, file, line, col, function(boxes)
            if #boxes == 0 then
                if tries > 0 then
                    local nxt = typeset_line(file, line + 1)
                    if nxt > line then
                        return ask_view(nxt, tries - 1)
                    end
                end
                return done(nil, ("%s is not in the PDF's SyncTeX data — rebuild"):format(fs.basename(file)))
            end
            local b = boxes[1]
            -- `point` is kept alongside the box because the two answer different questions: a viewer
            -- draws the BOX, while anything that maps back into the source (an inverse round trip)
            -- needs a point INSIDE the text — the box's top-left corner sits on the line above it.
            done({
                page = b.page,
                x = b.x,
                y = b.y,
                width = b.width,
                height = b.height,
                point = { x = b.x, y = b.y + b.height / 2 },
            }, nil)
        end)
    end

    ask_view(typeset_line(file, lnum), 3)
end

--- FORWARD, every box: each place on the page the line was typeset, in DOCUMENT order.
---
--- `M.view` answers with ONE box because a viewer that takes a point wants a point. A viewer that
--- takes a RECTANGLE LIST wants them all — and it wants them ordered, which is the whole reason this
--- exists: `synctex`'s own reply is not in document order (measured on a real paragraph: the first
--- record was its second-to-last typeset line), and a viewer that treats the first entry as "the"
--- position then marks an arbitrary line. Sorting by page and then by vertical position is what makes
--- "the first box" mean "where the line begins".
---
--- Degenerate boxes (`H == 0`) are dropped: they are records with no extent, and a rectangle of no
--- height is not a place on the page.
---
--- REPEATED boxes are dropped too, and that one is the difference between pointing at the text and
--- pointing at a page number. A paragraph broken across a page break leaves, on the EARLIER page, a
--- handful of byte-identical boxes down in the bottom margin — measured on a real book: 9 copies of
--- one geometry and 5 and 4 of two others, all at `v:713` on a page whose text ends far above it.
--- Ground truth from `pdftotext -bbox` says the only thing at those coordinates is the page NUMBER,
--- while the paragraph itself is a run of thirteen DISTINCT boxes on the next page. A typeset line
--- produces one box; a box the reply repeats is an artifact of the break. (If dropping them would
--- leave nothing at all, they are kept — an answer in the margin still beats no answer.)
---@param root string
---@param file string
---@param lnum integer
---@param col integer
---@param done fun(boxes: { page: integer, x: number, y: number, width: number, height: number }[]): nil
---@return nil
function M.view_boxes(root, file, lnum, col, done)
    if not M.available() then
        return done({})
    end
    local pdf = root_mod.pdf(root, state.project(root).target)
    if fn.filereadable(pdf) ~= 1 then
        return done({})
    end
    local ask = typeset_line(file, lnum)
    run(
        { "view", "-i", ("%d:%d:%s"):format(ask, math.max(1, col), file), "-o", pdf },
        fs.dirname(root),
        function(_, _, raw)
            local all, seen = {}, {}
            for _, rec in ipairs(M.records(raw)) do
                if rec.Page and rec.h and rec.v and rec.W and rec.H and rec.H > 0 and rec.W > 0 then
                    local key = ("%d:%f:%f:%f:%f"):format(rec.Page, rec.h, rec.v, rec.W, rec.H)
                    seen[key] = (seen[key] or 0) + 1
                    all[#all + 1] = {
                        key = key,
                        page = rec.Page,
                        x = rec.h,
                        y = math.max(0, rec.v - rec.H),
                        width = rec.W,
                        height = rec.H,
                    }
                end
            end
            local boxes, added = {}, {}
            for _, b in ipairs(all) do
                if seen[b.key] == 1 and not added[b.key] then
                    added[b.key] = true
                    boxes[#boxes + 1] = b
                end
            end
            if #boxes == 0 then
                for _, b in ipairs(all) do
                    if not added[b.key] then
                        added[b.key] = true
                        boxes[#boxes + 1] = b
                    end
                end
            end
            table.sort(boxes, function(a, b)
                if a.page ~= b.page then
                    return a.page < b.page
                end
                return a.y < b.y
            end)
            done(boxes)
        end
    )
end

--- Put the cursor on `file:lnum` and make that window current.
---
--- Reuses a window already showing the file rather than replacing the current buffer: an inverse
--- search arrives while the user is looking at something, and taking their window away is not what
--- "show me this line" means.
---@param file string
---@param lnum integer
---@param col integer?
---@return nil
function M.jump(file, lnum, col)
    if fn.filereadable(file) ~= 1 then
        notify(("inverse search names a file that is not there: %s"):format(file), vim.log.levels.WARN)
        return
    end
    local target = fs.normalize(fn.fnamemodify(file, ":p"))
    for _, win in ipairs(api.nvim_list_wins()) do
        local name = api.nvim_buf_get_name(api.nvim_win_get_buf(win))
        if name ~= "" and fs.normalize(name) == target then
            api.nvim_set_current_win(win)
            pcall(api.nvim_win_set_cursor, win, { math.max(1, lnum), math.max(0, (col or 1) - 1) })
            vim.cmd("normal! zz")
            return
        end
    end
    vim.cmd.edit(fn.fnameescape(target))
    pcall(api.nvim_win_set_cursor, 0, { math.max(1, lnum), math.max(0, (col or 1) - 1) })
    vim.cmd("normal! zz")
end

--- INVERSE from a PDF POSITION: resolve it through `synctex edit` and jump.
--- This is the path our own preview page takes — it can only report where it was clicked.
---@param pdf string   absolute path of the PDF
---@param page integer 1-based
---@param x number     PDF points from the page's top-left
---@param y number
---@return nil
function M.inverse(pdf, page, x, y)
    if not config.synctex.inverse then
        return
    end
    local ok, why = M.available()
    if not ok then
        notify(why or "synctex is unavailable", vim.log.levels.WARN)
        return
    end
    local spec = ("%d:%f:%f:%s"):format(page, x, y, pdf)
    run({ "edit", "-o", spec }, fs.dirname(pdf), function(f)
        local lnum = tonumber(f.Line)
        if not f.Input or not lnum then
            notify("inverse search found nothing at that point", vim.log.levels.WARN)
            return
        end
        local col = tonumber(f.Column) or -1
        M.jump(M.resolve_input(f.Input, fs.dirname(pdf)), lnum, col > 0 and col or 1)
    end)
end

-- ── the two-way scroll link ──────────────────────────────────────────────────
--
-- Forward search and `follow_back` move the same two things in opposite directions, so left alone
-- they chase each other: the cursor moves, the page scrolls, the page reports where it now is, the
-- source moves to meet it. Three mechanisms hold the link steady, and each answers a failure the
-- others cannot:
--
--   OWNERSHIP  whoever moved the other side last owns the link for `follow_back.settle` ms; a report
--              from the loser inside that window is dropped, and dropping it does not extend the
--              window, so control always changes hands after one quiet interval.
--   VALUE      neither side sends a line equal to the last one exchanged. The window alone cannot
--              carry this: a placement raises a scroll event whose debounced echo (400 ms) outlives
--              the window (300 ms), and the editor would answer its own movement.
--   GENERATION every accepted report takes a ticket. A report resolves through TWO async `synctex`
--              children, so a slower older report can finish AFTER a faster newer one and move the
--              source BACKWARDS while the page only went forwards. A stale ticket simply stops.
--
-- ALL OF IT IS PER LINK, keyed by the PDF. One project scrolling its preview must not lock out
-- another project's cursor-follow, and a global record made that impossible to express.

---@class LvimTexLink
---@field owner { side: "editor"|"viewer", deadline: integer }?  who moved the other side last
---@field line integer?   the last source line the two sides exchanged
---@field page integer?   the last PAGE, for a viewer that can only answer in pages
---@field gen integer     monotonic ticket for in-flight reports

---@type table<string, LvimTexLink>
local links = {}

--- The link record for `pdf`, created on demand.
---@param pdf string
---@return LvimTexLink
local function link(pdf)
    local l = links[pdf]
    if not l then
        l = { owner = nil, line = nil, page = nil, gen = 0 }
        links[pdf] = l
    end
    return l
end

--- Take the link for `side`.
---@param pdf string
---@param side "editor"|"viewer"
---@return nil
function M.claim_link(pdf, side)
    -- The window has to OUTLIVE the loser's in-flight movement, and the longest of those is the
    -- follow's own debounce: a placement raises a scroll event, the follow waits `follow_debounce`
    -- ms before acting on it, and if ownership has lapsed by then the editor answers its own move.
    -- Deriving the floor from that value rather than fixing a number is what keeps the invariant
    -- true for a user who tunes the debounce — with a plain 300 against a 400 ms debounce it was
    -- never true even at the defaults.
    local settle = math.max(0, (config.synctex.follow_back or {}).settle or 300)
    local floor = (tonumber(config.synctex.follow_debounce) or 400) + 150
    link(pdf).owner = { side = side, deadline = vim.uv.now() + math.max(settle, floor) }
end

--- Is `side` locked out — did the OTHER side move this link less than `settle` ms ago? Read-only: a
--- losing message must not extend the winner's window.
---@param pdf string
---@param side "editor"|"viewer"
---@return boolean
function M.link_locked_out(pdf, side)
    local o = links[pdf] and links[pdf].owner
    return o ~= nil and o.side ~= side and vim.uv.now() < o.deadline
end

--- Would sending `lnum` merely repeat the last line this link exchanged?
---@param pdf string
---@param lnum integer
---@return boolean
function M.link_repeats(pdf, lnum)
    return links[pdf] ~= nil and links[pdf].line == lnum
end

--- Record `lnum` as the line this link has now exchanged.
---
--- Called only once the movement has actually HAPPENED. Recording it up front — before an async
--- forward search resolves, or before a source window was found to move — makes a failed exchange
--- indistinguishable from a successful one, and then suppresses the retry that would have fixed it.
---@param pdf string
---@param lnum integer
---@return nil
function M.link_mark(pdf, lnum)
    link(pdf).line = lnum
end

--- Would moving to `page` merely repeat the page this link last exchanged?
---
--- The PAGE is a second currency on the same link, and it is needed because a position-capable
--- viewer answers in pages: `zathura` resolves `--synctex-forward` itself, so at send time we do not
--- know which page it landed on and the LINE equality cannot speak for it.
---@param pdf string
---@param page integer
---@return boolean
function M.link_repeats_page(pdf, page)
    return links[pdf] ~= nil and links[pdf].page == page
end

--- Record `page` as the page this link has now exchanged.
---@param pdf string
---@param page integer
---@return nil
function M.link_mark_page(pdf, page)
    link(pdf).page = page
end

--- Take a ticket for a new in-flight report on this link, invalidating every older one.
---@param pdf string
---@return integer
function M.link_ticket(pdf)
    local l = link(pdf)
    l.gen = l.gen + 1
    return l.gen
end

--- Is `ticket` still the newest for this link?
---@param pdf string
---@param ticket integer
---@return boolean
function M.link_current(pdf, ticket)
    return links[pdf] ~= nil and links[pdf].gen == ticket
end

--- Forget a link's state — one PDF's, or every one.
---
--- `setup()` and `:LvimTex reload` rebuild the autocmds and timers; without this the ownership and
--- the last exchanged line outlive them, so an old line can keep suppressing a perfectly valid
--- follow until something else changes it, and keys accumulate for the life of the session.
---@param pdf string?  nil clears every link
---@return nil
function M.reset(pdf)
    if pdf then
        links[pdf] = nil
    else
        links = {}
    end
end

--- Resolve a PDF POSITION to a source line and move the source there. The shared tail of every
--- reverse direction — the page's own report, and a page-granular poll of a viewer that can only
--- say which page it is on.
---@param pdf string
---@param page integer
---@param x number
---@param y number
---@param ticket integer  the caller's link ticket; a stale one stops here
---@param verify boolean  check the answer really sits near the point that produced it
---@return nil
local function resolve_and_place(pdf, page, x, y, ticket, verify)
    local back = config.synctex.follow_back or {}
    local cwd = fs.dirname(pdf)
    run({ "edit", "-o", ("%d:%f:%f:%s"):format(page, x, y, pdf) }, cwd, function(f)
        if not M.link_current(pdf, ticket) then
            return
        end
        local lnum = tonumber(f.Line)
        if not f.Input or not lnum then
            return
        end
        -- `synctex` answers with the name the ENGINE recorded, which may be relative — and relative
        -- to the CHILD's directory, not to Neovim's. Resolving it anywhere else finds nothing, or
        -- finds a same-named file in whatever directory the user happens to be in.
        local input = M.resolve_input(f.Input, cwd)

        --- Move the source to the answer, and record the exchange only if a window really moved.
        ---@return nil
        local function place()
            local ok, scroll = pcall(require, "lvim-preview.scroll")
            if not ok or type(scroll.place_source) ~= "function" then
                return
            end
            -- Claim BEFORE moving: `winrestview` raises CursorMoved / WinScrolled, and the follow
            -- must find the viewer owning the link rather than answer it with a forward search.
            M.claim_link(pdf, "viewer")
            local moved, at = scroll.place_source(input, lnum, { place = back.place, move = back.move })
            if moved then
                -- Marked with the line the window CAME TO REST on, not the one asked for: under
                -- 'wrap', and at the end of a file, they differ — and the follow measures the
                -- former, so marking the latter leaves it free to answer our own placement.
                M.link_mark(pdf, at or lnum)
                M.link_mark_page(pdf, page)
            end
        end

        local tolerance = tonumber(back.tolerance) or 0
        if not verify or tolerance <= 0 then
            return place()
        end
        -- IS THE ANSWER ABOUT WHAT THE READER IS LOOKING AT? A point in a page margin has no text
        -- under it, so `edit` answers with whatever record is nearest by its own metric — which is
        -- routinely a paragraph at the other end of the page. Asking `view` where that line really
        -- sits is the only way to tell the two apart, and it is only honest now that the reply is
        -- read as a RECORD LIST: the degenerate first record is self-consistent with the bad answer,
        -- so comparing against it would confirm the very thing it should refute.
        run({ "view", "-i", ("%d:1:%s"):format(lnum, input), "-o", pdf }, cwd, function(_, _, raw)
            if not M.link_current(pdf, ticket) then
                return
            end
            local rec = M.best_record(M.records(raw))
            if not rec or not rec.Page then
                return place()
            end
            if rec.Page ~= page then
                return
            end
            local real_y = (rec.v or rec.y or 0) - (rec.H or 0)
            if math.abs(real_y - y) > tolerance then
                return
            end
            place()
        end)
    end)
end

--- FOLLOW BACK: the viewer reports where its READER is; move the source to match.
---
--- Only the view is moved, and only in a window that already shows the file in the current tabpage
--- (`lvim-preview.scroll.place_source` owns that behaviour — it is the same problem the markdown
--- scroll link solved, and solving it twice is how the two drift apart). Nothing is opened, nothing
--- is focused, and a file the user is not looking at is simply not moved — in which case nothing is
--- recorded either, because no exchange took place.
---
--- The whole resolution is TICKETED: it runs through two async `synctex` children, so an older
--- report can finish after a newer one and would otherwise drag the source backwards.
---@param pdf string   absolute path of the PDF
---@param page integer 1-based
---@param x number     PDF points from the page's top-left
---@param y number
---@return nil
function M.follow_back(pdf, page, x, y)
    local back = config.synctex.follow_back or {}
    if not back.enabled or not config.synctex.inverse then
        return
    end
    -- We moved the page moments ago: this report is the echo of our own forward search.
    if M.link_locked_out(pdf, "viewer") then
        return
    end
    if not M.available() then
        return
    end
    resolve_and_place(pdf, page, x, y, M.link_ticket(pdf), true)
end

--- FOLLOW BACK BY PAGE: a viewer that can only say WHICH PAGE it is showing.
---
--- The coarse half of the same link, for a viewer whose interface exposes a page number and nothing
--- finer (zathura publishes `pagenumber`; okular `currentPage()`). The source then moves one page's
--- worth when the reader flips a page and not at all in between — which is what "follow along while
--- reading" means at that granularity, and all the data allows.
---
--- The query point is INSIDE the text block (`follow_back.poll.x/y`) rather than a page corner: a
--- page's margins carry no text, so a lookup there resolves to whatever record is nearest, routinely
--- the paragraph broken across the page break. For the same reason there is nothing to verify
--- against — the point is ours, not the reader's, so a tolerance check would only measure our own
--- choice of point.
---@param pdf string
---@param page integer  1-based
---@return nil
function M.follow_back_page(pdf, page)
    local back = config.synctex.follow_back or {}
    local poll = back.poll or {}
    if not back.enabled or not poll.enabled or not config.synctex.inverse then
        return
    end
    -- The page we ourselves put the viewer on: acting on it would answer our own forward search.
    if M.link_repeats_page(pdf, page) then
        return
    end
    if M.link_locked_out(pdf, "viewer") then
        return
    end
    if not M.available() then
        return
    end
    resolve_and_place(pdf, page, tonumber(poll.x) or 300, tonumber(poll.y) or 396, M.link_ticket(pdf), false)
end

--- REVERSE SEARCH, the explicit one: "the viewer is on this page — take me there".
---
--- The manual counterpart of `follow_back_page`, and deliberately a different action. A follow moves
--- the VIEW of a window that already shows the file, silently, because the user did not ask for it;
--- this is a command, so it JUMPS — cursor, and the window made current — and it says so when it
--- cannot, exactly as ctrl-click in a viewer does.
---
--- It also ignores `follow_back.poll.enabled`: that switch is about whether the editor should follow
--- the viewer BY ITSELF. Asking is always allowed.
---@param pdf string
---@param page integer  1-based
---@param done fun(ok: boolean, err: string?): nil
---@return nil
function M.reverse_page(pdf, page, done)
    if not config.synctex.inverse then
        return done(false, "synctex.inverse is off")
    end
    local ok, why = M.available()
    if not ok then
        return done(false, why)
    end
    local poll = (config.synctex.follow_back or {}).poll or {}
    local cwd = fs.dirname(pdf)
    local x, y = tonumber(poll.x) or 300, tonumber(poll.y) or 396
    run({ "edit", "-o", ("%d:%f:%f:%s"):format(page, x, y, pdf) }, cwd, function(f)
        local lnum = tonumber(f.Line)
        if not f.Input or not lnum then
            return done(false, ("nothing in the source is recorded at page %d"):format(page))
        end
        local col = tonumber(f.Column) or -1
        M.jump(M.resolve_input(f.Input, cwd), lnum, col > 0 and col or 1)
        -- The editor moved on the viewer's account: the link has exchanged this page, so the poll
        -- must not read it back a moment later and treat it as the reader having turned there.
        M.claim_link(pdf, "viewer")
        M.link_mark(pdf, lnum)
        M.link_mark_page(pdf, page)
        done(true, nil)
    end)
end

--- INVERSE from a FILE AND LINE — the entry point an EXTERNAL viewer calls.
---
--- Those viewers run `synctex` themselves (that is what their own `-x` / `--editor-cmd` setting is
--- for) and hand over the answer, so this side must not re-resolve anything. It is public and stable
--- because its name is embedded in viewer configuration that outlives this session: renaming it
--- breaks a setting the user pasted into a viewer's preferences.
---@param file string
---@param lnum integer|string   viewers substitute a raw number into the command string
---@param col integer|string?
---@return boolean ok  always true, so `--remote-expr` prints something harmless
function M.inverse_file_line(file, lnum, col)
    if not config.synctex.inverse then
        return true
    end
    vim.schedule(function()
        M.jump(file, tonumber(lnum) or 1, tonumber(col) or 1)
    end)
    return true
end

--- The command an external viewer runs to reach this Neovim, with `file` / `line` substituted for
--- that viewer's own placeholders.
---
--- Returns nil when this instance has no server socket (`nvim --listen ""`), which is the one case
--- where inverse search cannot work at all — health says so rather than handing out a broken string.
---@param placeholder { file: string, line: string }  e.g. { file = "%{input}", line = "%{line}" }
---@return string?
function M.editor_command(placeholder)
    local server = vim.v.servername
    if not server or server == "" then
        return nil
    end
    -- WHAT IS ESCAPED AND WHAT CANNOT BE. The two values we KNOW are shell-quoted: an executable path
    -- or a socket path containing a space would otherwise split into extra arguments and the callback
    -- would fail with something unrelated to its cause.
    --
    -- The placeholders cannot be: the VIEWER substitutes them, after this string is built, with a raw
    -- path we never see. The transport is therefore chosen to survive as much of one as possible —
    -- the expression is one shell argument in DOUBLE quotes (so spaces are safe), and the path lands
    -- in a Vim string literal in SINGLE quotes, which is the only Vim quoting in which a backslash is
    -- literal (a Windows path, or a TeX name with `\`, would otherwise be re-interpreted).
    --
    -- The residue is honest and bounded: a file name containing an apostrophe, a `$`, a backtick or a
    -- double quote cannot be transported through a viewer's own substitution this way, because the
    -- escaping would have to happen at substitution time and no viewer offers that. `M.jump` reports
    -- a file it cannot find rather than acting on a mangled one.
    local expr = ("v:lua.require('lvim-tex.synctex').inverse_file_line('%s',%s)"):format(
        placeholder.file,
        placeholder.line
    )
    return ('%s --server %s --remote-expr "%s"'):format(
        fn.shellescape(fn.exepath("nvim") ~= "" and fn.exepath("nvim") or "nvim"),
        fn.shellescape(server),
        expr
    )
end

return M
