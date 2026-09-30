-- Headless benchmark harness for smooth-scroll plugins.
--
-- Run (from any cwd):
--   BENCH_PLUGIN=/path/to/plugin BENCH_OUT=/tmp/x.json \
--     nvim --headless --clean -c 'luafile /path/to/bench.lua'
--
-- IMPORTANT: it must be started with `-c luafile` (NOT `nvim -l`): the
-- measurement runs as a coroutine driven by Neovim's real main loop, so that
-- typed keys (nvim_input), mappings, v:count, timers, WinScrolled/CursorMoved
-- and redraws behave exactly as in interactive use.  Inside `vim.wait()` the
-- main loop's normal_check() does not run, so WinScrolled/CursorMoved never
-- fire there, which is why vim.wait is not used for waiting on the animation.
--
-- Environment variables (all optional):
--   BENCH_PLUGIN      plugin dir prepended to 'rtp'; its plugin/** and
--                     after/plugin/** files are sourced.  Empty/"none" = native.
--   BENCH_LABEL       label stored in the output (default: basename of plugin).
--   BENCH_PRE         Lua chunk run BEFORE the plugin is sourced
--                     (e.g. 'vim.g.smoothie_experimental_mappings = 1').
--   BENCH_POST        Lua chunk run AFTER the plugin is sourced
--                     (e.g. 'require("smoothie").setup({})').
--   BENCH_BUSY        Lua expression, true while the plugin is still animating.
--                     Default: '#vim.fn.timer_info() > 0' (Vimscript timers).
--                     Completion = view unchanged for BENCH_SETTLE_MS AND not busy.
--   BENCH_ABORT       Lua chunk run after a timed-out run to stop the plugin's
--                     animation (e.g. 'require("smoothie").stop()').
--   BENCH_RUNS        repetitions per scenario (default 5); medians reported.
--   BENCH_SCENARIOS   comma-separated Lua patterns matched against scenario ids
--                     ("short/C-D", "folds/zt", "wrap/5xC-D", ...).  Default all.
--   BENCH_SETTLE_MS   quiet period that ends an animation (default 300).
--   BENCH_TIMEOUT_MS  animation considered stuck after this (default 6000).
--   BENCH_OUT         JSON output path (default: stdout summary only).
--   BENCH_PROFILE     if set, `:profile start $BENCH_PROFILE` + `:profile func *`
--                     for the whole run (Vimscript plugins only).
--   BENCH_LINES / BENCH_COLUMNS  screen size (default 50 x 120).
--   BENCH_MATCHPAREN  '0' runs :NoMatchParen (default: builtin matchparen on).
--   BENCH_UI_CHILD    set by bench_ui.lua; marks phases for the UI driver.
--
-- Per-run metrics (JSON `runs[]`; medians + _min/_max in `summary[]`):
--   frames          main-loop iterations in which winsaveview() changed
--                   (sampled from WinScrolled + CursorMoved, deduplicated)
--   dur_ms          first key sent -> last view change
--   first_ms        first key sent -> first view change (input latency)
--   cpu_us          process CPU (utime+stime) from first key until the plugin
--                   is idle after the last frame, minus the harness' own idle
--                   cost (idle_cpu_us_per_ms * wall time)
--   cpu_per_frame_us = cpu_us / frames
--   tick_cpu_us     median CPU between two consecutive frames (one animation
--                   step incl. redraw + autocmds), idle-corrected
--   first_cpu_us    CPU from key to the first frame (mapping + target calc)
--   max_gap_ms      largest gap between consecutive frames (stutter)
--   reversals_*     direction changes of topline/lnum (overshoot/"buzzing")
--   correct         final winsaveview() == native result, all of
--                   topline/lnum/col/curswant/topfill/skipcol/leftcol
--   timed_out       animation still changing/busy after BENCH_TIMEOUT_MS
--   j_ok            a plain `j` typed afterwards still moves the cursor
local uv = vim.uv or vim.loop
local api = vim.api
local fn = vim.fn

local env = vim.env
local function envnum(name, default)
  local v = tonumber(env[name] or '')
  return v or default
end

local cfg = {
  plugin = env.BENCH_PLUGIN or '',
  pre = env.BENCH_PRE,
  post = env.BENCH_POST,
  busy = env.BENCH_BUSY or '#vim.fn.timer_info() > 0',
  abort = env.BENCH_ABORT,
  runs = envnum('BENCH_RUNS', 5),
  settle_ms = envnum('BENCH_SETTLE_MS', 300),
  timeout_ms = envnum('BENCH_TIMEOUT_MS', 6000),
  check_ms = 10,
  out = env.BENCH_OUT,
  profile = env.BENCH_PROFILE,
  lines = envnum('BENCH_LINES', 50),
  columns = envnum('BENCH_COLUMNS', 120),
  ui_child = env.BENCH_UI_CHILD == '1',
  filter = env.BENCH_SCENARIOS,
}
if cfg.plugin == 'none' then cfg.plugin = '' end
cfg.label = env.BENCH_LABEL or (cfg.plugin ~= '' and fn.fnamemodify(cfg.plugin, ':t') or 'native')

local function hr_ms() return uv.hrtime() / 1e6 end
local function cpu_us()
  local r = uv.getrusage()
  return (r.utime.sec + r.stime.sec) * 1e6 + r.utime.usec + r.stime.usec
end

local VIEW_KEYS = { 'topline', 'lnum', 'col', 'curswant', 'topfill', 'skipcol', 'leftcol' }
local function view_eq(a, b, keys)
  for _, k in ipairs(keys or VIEW_KEYS) do
    if a[k] ~= b[k] then return false end
  end
  return true
end
local function view_str(v)
  return ('top=%d lnum=%d col=%d want=%d fill=%d skip=%d'):format(v.topline, v.lnum, v.col, v.curswant,
    v.topfill, v.skipcol)
end

---------------------------------------------------------------------------
-- UI-driver phase markers (only when run as a child of bench_ui.lua)
---------------------------------------------------------------------------
local ui_chan
local function mark(tag, data)
  if not cfg.ui_child then return end
  if not ui_chan then
    local uis = api.nvim_list_uis()
    ui_chan = uis[1] and uis[1].chan
  end
  if ui_chan then fn.rpcnotify(ui_chan, 'bench_mark', tag, data or {}) end
end

---------------------------------------------------------------------------
-- Global editor setup
---------------------------------------------------------------------------
if not cfg.ui_child then
  vim.o.lines = cfg.lines
  vim.o.columns = cfg.columns
end
vim.o.shortmess = vim.o.shortmess .. 'IFW'
vim.o.more = false
vim.o.swapfile = false
vim.o.hidden = true

local busy_fn
do
  local chunk, err = loadstring('return ' .. cfg.busy)
  assert(chunk, 'BENCH_BUSY: ' .. tostring(err))
  busy_fn = function()
    local ok, res = pcall(chunk)
    return ok and res and true or false
  end
end

if cfg.pre and cfg.pre ~= '' then assert(loadstring(cfg.pre, 'BENCH_PRE'))() end

local load_us = 0
if cfg.plugin ~= '' then
  local c0 = cpu_us()
  vim.opt.rtp:prepend(cfg.plugin)
  vim.opt.rtp:append(cfg.plugin .. '/after')
  for _, sub in ipairs({ 'plugin', 'after/plugin' }) do
    local files = fn.globpath(cfg.plugin, sub .. '/**/*.vim', false, true)
    vim.list_extend(files, fn.globpath(cfg.plugin, sub .. '/**/*.lua', false, true))
    table.sort(files)
    for _, f in ipairs(files) do vim.cmd.source(fn.fnameescape(f)) end
  end
  load_us = cpu_us() - c0
end
if cfg.post and cfg.post ~= '' then assert(loadstring(cfg.post, 'BENCH_POST'))() end
-- matchparen (a default plugin, on in --clean) runs on every CursorMoved and
-- costs ~170 us per animation frame; keep it on by default (realistic),
-- BENCH_MATCHPAREN=0 turns it off to isolate plugin cost.
cfg.matchparen = env.BENCH_MATCHPAREN ~= '0'
if not cfg.matchparen then vim.cmd('silent! NoMatchParen') end

---------------------------------------------------------------------------
-- Test buffers
---------------------------------------------------------------------------
local BUFS = {}

BUFS.short = {
  make = function()
    local l = {}
    for i = 1, 10000 do l[i] = ('%05d the quick brown fox jumps'):format(i) end
    return l
  end,
  wo = { wrap = false, foldenable = false, foldmethod = 'manual' },
}

local function long_line(i)
  local s = ('%05d '):format(i) .. string.rep('wrapped text chunk ', 20)
  return s:sub(1, 300)
end

BUFS.wrap = {
  make = function()
    local l = {}
    for i = 1, 5000 do l[i] = (i % 3 == 0) and long_line(i) or ('%05d short line'):format(i) end
    return l
  end,
  wo = { wrap = true, foldenable = false, foldmethod = 'manual', smoothscroll = false },
}

-- same text as `wrap`, with 'smoothscroll' (skipcol-based scrolling, nvim >= 0.10)
BUFS.wrapss = {
  make = BUFS.wrap.make,
  wo = { wrap = true, foldenable = false, foldmethod = 'manual', smoothscroll = true },
}

-- period of 12 lines: 1 fold header, 7 body, 1 fold end (all closed) + 3 plain
BUFS.folds = {
  make = function()
    local l = {}
    for i = 1, 10000 do
      local o = (i - 1) % 12
      if o == 0 then
        l[i] = ('%05d fold header {{{'):format(i)
      elseif o <= 7 then
        l[i] = ('%05d    folded body'):format(i)
      elseif o == 8 then
        l[i] = ('%05d    }}}'):format(i)
      else
        l[i] = ('%05d plain line'):format(i)
      end
    end
    return l
  end,
  wo = { wrap = false, foldenable = true, foldmethod = 'marker', foldlevel = 0 },
}

local BUF_ORDER = { 'short', 'wrap', 'wrapss', 'folds' }
local line_cache = {}

local COMMON_WO = {
  number = false, relativenumber = false, scrolloff = 0, sidescrolloff = 0, list = false,
  cursorline = false, signcolumn = 'no', foldcolumn = '0', smoothscroll = false,
  scroll = 0, -- a count to <C-D>/<C-U> sets 'scroll'; reset it (0 = half window)
}

local function new_buffer(kind)
  local spec = BUFS[kind]
  line_cache[kind] = line_cache[kind] or spec.make()
  local win = api.nvim_get_current_win()
  local old = api.nvim_get_current_buf()
  local buf = api.nvim_create_buf(true, true)
  api.nvim_buf_set_lines(buf, 0, -1, false, line_cache[kind])
  vim.bo[buf].undolevels = -1
  vim.bo[buf].modified = false
  api.nvim_win_set_buf(win, buf)
  for k, v in pairs(COMMON_WO) do vim.wo[win][0][k] = v end
  for k, v in pairs(spec.wo) do vim.wo[win][0][k] = v end
  if spec.wo.foldmethod == 'marker' then vim.cmd('normal! zM') end
  if old ~= buf and api.nvim_buf_is_valid(old) and old ~= 1 then
    pcall(api.nvim_buf_delete, old, { force = true })
  end
  return buf
end

-- screen rows occupied by buffer lines [a, b]
local function rows_between(win, a, b)
  return api.nvim_win_text_height(win, { start_row = a - 1, end_row = b - 1 }).all
end

-- smallest topline t <= lnum such that lines [t, lnum] fit in `rows` screen rows
local function topline_for(win, lnum, rows)
  local t = lnum
  while t > 1 do
    local cand = t - 1
    local fc = fn.foldclosed(cand)
    if fc ~= -1 then cand = fc end
    if rows_between(win, cand, lnum) > rows then break end
    t = cand
  end
  return t
end

-- first line >= l that is not inside a closed fold and is a short (non-wrapping) line
local function plain_line(l)
  local last = fn.line('$')
  while l < last do
    if fn.foldclosed(l) == -1 and #fn.getline(l) < 60 then return l end
    l = l + 1
  end
  return l
end

---------------------------------------------------------------------------
-- Scenarios
---------------------------------------------------------------------------
-- start = 'mid': cursor ~40% into the buffer, 10 screen rows below topline
-- start = 'low': cursor ~40% into the buffer, 40 screen rows below topline
-- start = 'top': topline = lnum = 1          (vim-smoothie issue #47)
-- start = 'end': cursor on the last line, at the bottom of the window
local CMDS = {
  { id = 'C-D', keys = '<C-D>', start = 'mid' },
  { id = 'C-U', keys = '<C-U>', start = 'mid' },
  { id = 'C-F', keys = '<C-F>', start = 'mid' },
  { id = 'C-B', keys = '<C-B>', start = 'mid' },
  { id = 'zz', keys = 'zz', start = 'low' },
  { id = 'zt', keys = 'zt', start = 'low' },
  { id = 'zb', keys = 'zb', start = 'mid' },
  { id = 'G', keys = 'G', start = 'mid' },
  { id = 'gg', keys = 'gg', start = 'mid' },
  { id = '5xC-D', keys = '<C-D>', rep = 5, gap_ms = 10, start = 'mid' },
  { id = '10C-D', keys = '10<C-D>', start = 'mid' },
  { id = 'C-D@top', keys = '<C-D>', start = 'top' },
  { id = 'C-U@end', keys = '<C-U>', start = 'end' },
}

local function start_view(kind, start)
  local _ = kind
  local win = api.nvim_get_current_win()
  local n = fn.line('$')
  local height = api.nvim_win_get_height(win)
  local v = { col = 6, curswant = 6, topfill = 0, skipcol = 0, leftcol = 0 }
  if start == 'top' then
    v.topline, v.lnum = 1, 1
  elseif start == 'end' then
    v.lnum = n
    v.topline = topline_for(win, n, height - 1)
  else
    v.lnum = plain_line(math.floor(n * 0.4))
    v.topline = topline_for(win, v.lnum, start == 'low' and 40 or 10)
  end
  return v
end

local scenarios = {}
do
  local pats
  if cfg.filter and cfg.filter ~= '' then pats = vim.split(cfg.filter, ',', { trimempty = true }) end
  for _, b in ipairs(BUF_ORDER) do
    for _, c in ipairs(CMDS) do
      local id = b .. '/' .. c.id
      local keep = not pats
      for _, p in ipairs(pats or {}) do
        if id:find(p) then keep = true end
      end
      if keep then scenarios[#scenarios + 1] = { id = id, buf = b, cmd = c } end
    end
  end
end

---------------------------------------------------------------------------
-- Coroutine driver on top of the real main loop
---------------------------------------------------------------------------
local co
local function resume(...)
  local ok, err = coroutine.resume(co, ...)
  if not ok then
    io.stderr:write('bench.lua error: ' .. tostring(err) .. '\n' .. debug.traceback(co) .. '\n')
    vim.cmd('cquit 2')
  end
end
local function sleep(ms)
  vim.defer_fn(resume, ms)
  coroutine.yield()
end

-- frame recorder: every main-loop iteration in which the view changed fires
-- WinScrolled and/or CursorMoved; dedupe by comparing winsaveview().
local rec = { active = false }
local augroup = api.nvim_create_augroup('bench_recorder', { clear = true })
api.nvim_create_autocmd({ 'WinScrolled', 'CursorMoved' }, {
  group = augroup,
  callback = function()
    if not rec.active then return end
    local v = fn.winsaveview()
    if not view_eq(v, rec.last) then
      local f = { t = hr_ms(), c = cpu_us(), topline = v.topline, lnum = v.lnum, skipcol = v.skipcol }
      rec.frames[#rec.frames + 1] = f
      rec.last = v
    end
  end,
})

local function termcodes(k) return api.nvim_replace_termcodes(k, true, false, true) end

-- Expected final view: the same keys, fed as NON-remappable typeahead
-- (feedkeys mode 'n', so plugin mappings are bypassed) and executed by the
-- main loop with the same inter-key gap, so that topline is validated by the
-- normal redraw path exactly like in interactive use.  (feedkeys 'x' + an
-- immediate winsaveview() is NOT equivalent: after e.g. `G` the topline is
-- only updated lazily at redraw time, so winsaveview() still returns the old
-- topline.)
local function expected_view(sc, sv)
  new_buffer(sc.buf)
  fn.winrestview(sv)
  sleep(30)
  local normalized = fn.winsaveview()
  for _ = 1, sc.cmd.rep or 1 do
    api.nvim_feedkeys(termcodes(sc.cmd.keys), 'n', false) -- 'n' = noremap -> native command
    sleep(sc.cmd.gap_ms or 10)
  end
  sleep(30)
  return fn.winsaveview(), normalized
end

local idle_rate = 0 -- harness CPU per ms of wall time while idle

local function calibrate_idle()
  new_buffer('short')
  sleep(50)
  local c0, t0 = cpu_us(), hr_ms()
  while hr_ms() - t0 < 1000 do
    sleep(cfg.check_ms)
    local _ = hr_ms(), busy_fn(), cpu_us()
  end
  idle_rate = (cpu_us() - c0) / (hr_ms() - t0)
end

local function reversals(frames, start, key)
  local n, dir, prev = 0, 0, start[key]
  for _, f in ipairs(frames) do
    local d = f[key] - prev
    if d ~= 0 then
      local s = d > 0 and 1 or -1
      if dir ~= 0 and s ~= dir then n = n + 1 end
      dir = s
      prev = f[key]
    end
  end
  return n
end

local function run_once(sc, run_idx)
  local win = api.nvim_get_current_win()
  -- expected (native) final view on an identical fresh buffer
  new_buffer(sc.buf)
  local sv = start_view(sc.buf, sc.cmd.start)
  local exp, sv_norm = expected_view(sc, sv)

  -- the measured run, on another identical fresh buffer
  new_buffer(sc.buf)
  fn.winrestview(sv)
  sleep(30) -- let setup-induced WinScrolled/CursorMoved/redraw settle
  sleep(30)
  local start = fn.winsaveview()
  assert(view_eq(start, sv_norm), 'start view mismatch: ' .. view_str(start) .. ' vs ' .. view_str(sv_norm))

  rec.frames = {}
  rec.last = start
  rec.active = true
  mark('start', { id = sc.id, run = run_idx })
  local rep = sc.cmd.rep or 1
  local sent = 0
  local t_last_input
  local c0, t0 = cpu_us(), hr_ms()
  local function send()
    sent = sent + 1
    t_last_input = hr_ms()
    api.nvim_input(sc.cmd.keys)
  end
  send()
  for i = 2, rep do
    vim.defer_fn(send, (i - 1) * sc.cmd.gap_ms)
  end

  local timed_out = false
  local busy_at_end = false
  local t_done
  -- idle_pt: first check of the current idle streak (all keys sent, plugin not
  -- busy) that happened after the last observed frame.  CPU is accounted up to
  -- that point, so the long settle period does not dilute the numbers.
  local idle_pt
  while true do
    sleep(cfg.check_ms)
    local now, c, b = hr_ms(), cpu_us(), busy_fn()
    local last_change = rec.frames[#rec.frames] and rec.frames[#rec.frames].t or t0
    if sent < rep or b then
      idle_pt = nil
    elseif not idle_pt or last_change > idle_pt.t then
      idle_pt = { t = now, c = c }
    end
    local quiet_since = math.max(last_change, t_last_input)
    if idle_pt and now - quiet_since >= cfg.settle_ms then
      t_done = now
      break
    end
    if now - t0 > cfg.timeout_ms then
      timed_out = true
      busy_at_end = b
      t_done = now
      break
    end
  end
  local c_done = cpu_us()
  idle_pt = idle_pt or { t = t_done, c = c_done }
  rec.active = false
  mark('end', { id = sc.id, run = run_idx })
  local final = fn.winsaveview()
  -- a stuck animation must not leak into the next run.  vim-smoothie stops on
  -- BufLeave (new_buffer() switches buffers); other plugins can provide an
  -- explicit stop hook via BENCH_ABORT (Lua chunk).
  if timed_out and cfg.abort and cfg.abort ~= '' then
    local ok, err = pcall(assert(loadstring(cfg.abort, 'BENCH_ABORT')))
    if not ok then io.stderr:write('BENCH_ABORT failed: ' .. tostring(err) .. '\n') end
  end

  -- post-check: does a plain `j` still move the cursor? (vim-smoothie #40)
  local j_ok = true
  if final.lnum < fn.line('$') and fn.foldclosedend(final.lnum) < fn.line('$') then
    api.nvim_input('j')
    sleep(80)
    j_ok = fn.line('.') ~= final.lnum
  end

  local frames = rec.frames
  local nf = #frames
  local last = frames[nf]
  local gaps, prev = {}, t0
  for _, f in ipairs(frames) do
    gaps[#gaps + 1] = f.t - prev
    prev = f.t
  end
  local max_gap, sum_gap = 0, 0
  for _, g in ipairs(gaps) do
    max_gap = math.max(max_gap, g)
    sum_gap = sum_gap + g
  end
  -- steady-state per-frame CPU: CPU between consecutive frames, minus the
  -- harness idle cost for that wall interval
  local tick = {}
  for i = 2, nf do
    tick[#tick + 1] = (frames[i].c - frames[i - 1].c) - idle_rate * (frames[i].t - frames[i - 1].t)
  end
  table.sort(tick)
  local r = {
    id = sc.id,
    run = run_idx,
    frames = nf,
    dur_ms = last and (last.t - t0) or 0,
    first_ms = frames[1] and (frames[1].t - t0) or 0,
    first_cpu_us = frames[1] and (frames[1].c - c0) or 0,
    cpu_to_last_us = last and (last.c - c0) or 0,
    cpu_raw_us = c_done - c0,
    cpu_us = math.max(0, (idle_pt.c - c0) - idle_rate * (idle_pt.t - t0)),
    tick_cpu_us = #tick > 0 and tick[math.floor((#tick + 1) / 2)] or 0,
    idle_after_ms = idle_pt.t - (last and last.t or t0),
    max_gap_ms = max_gap,
    mean_gap_ms = nf > 0 and sum_gap / nf or 0,
    reversals_top = reversals(frames, start, 'topline'),
    reversals_lnum = reversals(frames, start, 'lnum'),
    timed_out = timed_out,
    busy_at_end = busy_at_end,
    correct = view_eq(final, exp),
    correct_topline_lnum = view_eq(final, exp, { 'topline', 'lnum' }),
    j_ok = j_ok,
    start = start,
    expected = exp,
    final = final,
    dist_top = math.abs(exp.topline - start.topline),
    dist_lnum = math.abs(exp.lnum - start.lnum),
  }
  r.cpu_per_frame_us = nf > 0 and r.cpu_us / nf or 0
  -- compact per-frame trace: {ms since key, topline, lnum, skipcol}
  r.trace = {}
  for _, f in ipairs(frames) do
    r.trace[#r.trace + 1] = { math.floor((f.t - t0) * 10 + 0.5) / 10, f.topline, f.lnum, f.skipcol }
  end
  if not r.correct then
    r.mismatch = { 'final ' .. view_str(final), 'expect ' .. view_str(exp) }
  end
  -- abort any animation still running before the next scenario
  local _ = win
  return r
end

local function median(xs)
  if #xs == 0 then return 0 end
  local s = vim.deepcopy(xs)
  table.sort(s)
  local m = math.floor((#s + 1) / 2)
  if #s % 2 == 1 then return s[m] end
  return (s[m] + s[m + 1]) / 2
end

local NUM_FIELDS = { 'frames', 'dur_ms', 'first_ms', 'first_cpu_us', 'cpu_us', 'cpu_to_last_us', 'cpu_raw_us',
  'cpu_per_frame_us', 'tick_cpu_us', 'idle_after_ms', 'max_gap_ms', 'mean_gap_ms', 'reversals_top',
  'reversals_lnum' }

local function summarize(runs)
  local s = { id = runs[1].id, runs = #runs, dist_top = runs[1].dist_top, dist_lnum = runs[1].dist_lnum }
  for _, k in ipairs(NUM_FIELDS) do
    local xs = {}
    for _, r in ipairs(runs) do xs[#xs + 1] = r[k] end
    s[k] = median(xs)
    s[k .. '_min'] = math.min(unpack(xs))
    s[k .. '_max'] = math.max(unpack(xs))
  end
  s.correct = 0
  s.correct_topline_lnum = 0
  s.timeouts = 0
  s.j_ok = 0
  for _, r in ipairs(runs) do
    if r.correct then s.correct = s.correct + 1 end
    if r.correct_topline_lnum then s.correct_topline_lnum = s.correct_topline_lnum + 1 end
    if r.timed_out then s.timeouts = s.timeouts + 1 end
    if r.j_ok then s.j_ok = s.j_ok + 1 end
    if r.mismatch and not s.mismatch then s.mismatch = r.mismatch end
  end
  return s
end

local function fmt_table(summ)
  local out = {}
  out[#out + 1] = ('%-14s %4s %6s %8s %7s %8s %8s %8s %7s %4s %7s %4s %3s'):format('scenario', 'dist', 'frames',
    'dur_ms', 'first', 'cpu_ms', 'us/frm', 'us/intv', 'maxgap', 'rev', 'correct', 'tmo', 'j')
  for _, s in ipairs(summ) do
    out[#out + 1] = ('%-14s %4d %6.0f %8.1f %7.1f %8.2f %8.0f %8.0f %7.1f %4.0f %5d/%d %4d %3d'):format(s.id,
      math.max(s.dist_top, s.dist_lnum), s.frames, s.dur_ms, s.first_ms, s.cpu_us / 1000, s.cpu_per_frame_us,
      s.tick_cpu_us, s.max_gap_ms, s.reversals_top + s.reversals_lnum, s.correct, s.runs, s.timeouts, s.j_ok)
    if s.mismatch then out[#out + 1] = '      ! ' .. table.concat(s.mismatch, ' | ') end
  end
  return table.concat(out, '\n')
end

local function main()
  sleep(100)
  if cfg.profile and cfg.profile ~= '' then
    vim.cmd('profile start ' .. fn.fnameescape(cfg.profile))
    vim.cmd('profile func *')
  end
  calibrate_idle()
  local all_runs, summ = {}, {}
  for _, sc in ipairs(scenarios) do
    local runs = {}
    for i = 1, cfg.runs do
      local r = run_once(sc, i)
      runs[#runs + 1] = r
      all_runs[#all_runs + 1] = r
    end
    summ[#summ + 1] = summarize(runs)
  end
  if cfg.profile and cfg.profile ~= '' then vim.cmd('profile stop') end
  local result = {
    label = cfg.label,
    plugin = cfg.plugin,
    pre = cfg.pre,
    post = cfg.post,
    nvim = tostring(vim.version()),
    lines = vim.o.lines,
    columns = vim.o.columns,
    winheight = api.nvim_win_get_height(0),
    runs_per_scenario = cfg.runs,
    settle_ms = cfg.settle_ms,
    timeout_ms = cfg.timeout_ms,
    idle_cpu_us_per_ms = idle_rate,
    matchparen = cfg.matchparen,
    plugin_load_cpu_us = load_us,
    summary = summ,
    runs = all_runs,
  }
  local text = ('# %s  (nvim %s, %dx%d, win height %d, runs=%d, idle harness cpu %.2f us/ms, load %.0f us)\n')
      :format(cfg.label, result.nvim, result.columns, result.lines, result.winheight, cfg.runs, idle_rate, load_us)
      .. fmt_table(summ) .. '\n'
  if cfg.out and cfg.out ~= '' then
    fn.writefile({ vim.json.encode(result) }, cfg.out)
    fn.writefile(vim.split(text, '\n'), cfg.out .. '.txt')
  end
  -- in --embed mode stdout is the RPC channel: never write to it
  if not cfg.ui_child then io.stdout:write(text) end
  mark('done', {})
  vim.cmd('qall!')
end

co = coroutine.create(main)
vim.schedule(resume)
