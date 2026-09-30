local api, fn, uv = vim.api, vim.fn, vim.uv

local H = {}

H.HEIGHT, H.WIDTH = 48, 120
H.NATIVE = { keys = {}, jumps = false, search = false, mouse = false }
H.SETTLE = {}
H.FULL = vim.env.SMOOTHIE_TEST_FULL == '1'
H.VERBOSE = vim.env.SMOOTHIE_TEST_VERBOSE == '1'
H.VIRT_LINES = { { { 'v1' } }, { { 'v2' } } }
H.tests = {}

local POLL_MS, QUIET_MS, STUCK_MS = 10, 100, 3000
local SAMPLE_MS, START_MS, STALL_MS = 2, 30, 20000
local MAX_DETAIL, SLOW_S = 5, 5
local AUG = api.nvim_create_augroup('smoothie_test', { clear = true })
local NS = api.nvim_create_namespace('smoothie_test')
local NS_VLINES = api.nvim_create_namespace('smoothie_test_vlines')

local function smoothie() return require('smoothie') end

function H.now() return uv.hrtime() / 1e6 end

function H.out(line)
  io.stdout:write(line, '\n')
  io.stdout:flush()
end

-- Driver: one coroutine, resumed from the real main loop by vim.defer_fn.

local co, current, aborted
local last_progress = 0

local function one_line(s) return (tostring(s):gsub('%s*\n%s*', ' | ')) end

local function report_abort(msg)
  aborted = true
  H.out(string.format('FAIL %s %s harness: %s', current and current.id or '-', current and current.name or '-', one_line(msg)))
end

local function abort(msg)
  report_abort(msg)
  vim.cmd('cquit 1')
end

local function resume()
  if aborted then return end
  last_progress = H.now()
  local ok, err = coroutine.resume(co)
  if not ok then abort(debug.traceback(co, tostring(err))) end
end

function H.sleep(ms)
  vim.defer_fn(resume, ms)
  coroutine.yield()
end

function H.system(cmd)
  local res
  vim.system(cmd, { text = true }, function(o)
    res = o
    vim.schedule(resume)
  end)
  coroutine.yield()
  return res
end

-- Views and state capture.

function H.view(win) return api.nvim_win_call(win or 0, fn.winsaveview) end

function H.vstr(win)
  local v = H.view(win)
  return string.format('top=%d fill=%d skip=%d left=%d lnum=%d col=%d add=%d want=%d',
    v.topline, v.topfill, v.skipcol, v.leftcol, v.lnum, v.col, v.coladd, v.curswant)
end

function H.buffer_text(buf)
  return table.concat(api.nvim_buf_get_lines(buf or 0, 0, -1, false), '\n')
end

-- The full comparison set of the current window.
function H.capture()
  local v = fn.winsaveview()
  local jl = fn.getjumplist()
  local jumps = {}
  for i, j in ipairs(jl[1]) do jumps[i] = j.lnum end
  local c = {
    topline = v.topline, topfill = v.topfill, skipcol = v.skipcol, leftcol = v.leftcol,
    lnum = v.lnum, col = v.col, coladd = v.coladd, curswant = v.curswant,
    mode = api.nvim_get_mode().mode,
    lines = H.buffer_text(),
    scroll = vim.wo.scroll,
    jumps = table.concat(jumps, ',') .. ' @' .. jl[2],
    search = fn.getreg('/'),
    hlsearch = vim.v.hlsearch,
    reg = fn.getreg('"'),
    regtype = fn.getregtype('"'),
  }
  if vim.wo.foldenable then
    local f = {}
    for l = fn.line('w0'), fn.line('w$') do f[#f + 1] = fn.foldclosed(l) end
    c.folds = table.concat(f, ',')
  end
  return c
end

local function show(v)
  if type(v) ~= 'string' then return tostring(v) end
  local s = string.format('%q', v):gsub('\\\n', '\\n')
  return #s > 60 and (s:sub(1, 57) .. '...') or s
end

local function first_line_diff(a, b)
  local la, lb = vim.split(a or '', '\n', { plain = true }), vim.split(b or '', '\n', { plain = true })
  for i = 1, math.max(#la, #lb) do
    if la[i] ~= lb[i] then
      return string.format('line %d plugin=%s native=%s (lines %d vs %d)', i, show(la[i]), show(lb[i]), #la, #lb)
    end
  end
  return 'equal'
end

function H.diff(p, n)
  local keys, seen = {}, {}
  for _, t in ipairs({ p, n }) do
    for k in pairs(t) do
      if not seen[k] then
        seen[k] = true
        keys[#keys + 1] = k
      end
    end
  end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do
    if p[k] ~= n[k] then
      if k == 'lines' then
        out[#out + 1] = 'buffer ' .. first_line_diff(p[k], n[k])
      else
        out[#out + 1] = string.format('%s plugin=%s native=%s', k, show(p[k]), show(n[k]))
      end
    end
  end
  return out
end

-- Sampler: a 2 ms uv timer that schedules a record whenever the observed state changes.

local smp = { on = false, pending = false, rec = {}, keys = {} }

local function same(a, b)
  return a.top == b.top and a.fill == b.fill and a.skip == b.skip and a.lnum == b.lnum
    and a.col == b.col and a.left == b.left and a.mode == b.mode
end

function H.sample()
  smp.pending = false
  if not smp.on then return end
  if smoothie().is_animating() then
    smp.anim_ever = true
    smp.last_anim = H.now()
  end
  if not api.nvim_win_is_valid(smp.win) then return end
  local r
  api.nvim_win_call(smp.win, function()
    local v = fn.winsaveview()
    r = { top = v.topline, fill = v.topfill, skip = v.skipcol, lnum = v.lnum, col = v.col, left = v.leftcol,
      fc = fn.foldclosed(v.lnum) }
  end)
  r.mode = api.nvim_get_mode().mode
  r.t = H.now()
  local last = smp.rec[#smp.rec]
  if not last or not same(last, r) then smp.rec[#smp.rec + 1] = r end
end

local function start_sampler(win)
  smp.win, smp.rec, smp.keys, smp.on, smp.anim_ever, smp.last_anim = win, {}, {}, true, false, nil
  H.sample()
  smp.timer = smp.timer or uv.new_timer()
  smp.timer:start(SAMPLE_MS, SAMPLE_MS, function()
    if not smp.pending then
      smp.pending = true
      vim.schedule(H.sample)
    end
  end)
end

local function stop_sampler()
  smp.timer:stop()
  smp.on = false
end

vim.on_key(function(_, typed)
  if typed == nil or typed == '' then return end
  if smp.on then smp.keys[#smp.keys + 1] = { t = H.now(), typed = fn.keytrans(typed) } end
  if H.key_hook then H.key_hook(fn.keytrans(typed)) end
end, NS)

-- Settle: not animating and view + mode unchanged for QUIET_MS; gives up after STUCK_MS.
function H.settle()
  local t0 = H.now()
  local last, quiet_since
  while true do
    H.sleep(POLL_MS)
    local t = H.now()
    local state = H.vstr(0) .. ' ' .. api.nvim_get_mode().mode
    if smoothie().is_animating() or state ~= last then quiet_since = t end
    last = state
    if t - quiet_since >= QUIET_MS then return true, quiet_since end
    if t - t0 >= STUCK_MS then return false, quiet_since end
  end
end

-- Pinned defaults.

local maps, cleanups = {}, {}

function H.map(mode, lhs, rhs, opts)
  vim.keymap.set(mode, lhs, rhs, opts)
  maps[#maps + 1] = { mode, lhs }
end

function H.au(events, callback)
  api.nvim_create_autocmd(events, { group = AUG, callback = callback })
end

function H.on_cleanup(f) cleanups[#cleanups + 1] = f end

function H.cleanup()
  H.key_hook = nil
  local E = package.loaded['smoothie.engine']
  if E then E._fault = nil end
  for i = #cleanups, 1, -1 do cleanups[i]() end
  cleanups = {}
  api.nvim_clear_autocmds({ group = AUG })
  for _, m in ipairs(maps) do
    assert(fn.maparg(m[2], m[1]) ~= '', 'test mapping vanished: ' .. m[1] .. ' ' .. m[2])
    vim.keymap.del(m[1], m[2])
  end
  maps = {}
end

function H.setup(opts) smoothie().setup(vim.deepcopy(opts or {})) end

function H.reset()
  smoothie().stop()
  if api.nvim_get_mode().mode ~= 'n' then
    api.nvim_input('<C-\\><C-N>')
    local t0 = H.now()
    repeat
      H.sleep(5)
    until api.nvim_get_mode().mode == 'n' or H.now() - t0 > STUCK_MS
    assert(api.nvim_get_mode().mode == 'n', 'cannot leave mode ' .. api.nvim_get_mode().mode)
  end
  H.cleanup()
  H.setup(H.NATIVE)
  vim.cmd('diffoff!')
  local cur = api.nvim_get_current_win()
  for _, w in ipairs(api.nvim_list_wins()) do
    if w ~= cur then api.nvim_win_close(w, true) end
  end
  local buf = api.nvim_create_buf(true, true)
  api.nvim_win_set_buf(cur, buf)
  for _, b in ipairs(api.nvim_list_bufs()) do
    if b ~= buf then api.nvim_buf_delete(b, { force = true }) end
  end
  -- A resize reuses a hidden row fraction (w_fraction) while the cursor row equals the one of the
  -- last resize, so an earlier test's resizes (a command-line window) could change a later split.
  -- Resizing here with the cursor on row 0 makes that state the same before every test.
  vim.cmd('split')
  vim.cmd('close')
  vim.cmd('set scrolloff=0 sidescrolloff=0 nostartofline belloff=all foldopen& foldclose= mouse=nvi'
    .. ' mousescroll=ver:3,hor:6 nomousemoveevent hlsearch& cmdheight=1 laststatus=2 noshowmode')
  vim.cmd('set nowrap nosmoothscroll nofoldenable foldmethod=manual foldlevel=0 foldcolumn=0 scroll=0'
    .. ' noscrollbind nocursorbind nonumber nodiff conceallevel=0 concealcursor=')
  vim.cmd('setlocal scrolloff=-1 sidescrolloff=-1')
  vim.cmd('clearjumps')
  fn.setreg('"', '')
  fn.setreg('q', '')
  fn.setreg('/', '')
  vim.g.smoothie_enabled = nil
  vim.g.neovide = nil
  vim.g.started_by_firenvim = nil
  vim.w.smoothie_enabled = nil
  vim.v.hlsearch = 0
  vim.v.errmsg = ''
  vim.cmd('messages clear')
  assert(api.nvim_win_get_height(cur) == H.HEIGHT and api.nvim_win_get_width(cur) == H.WIDTH,
    string.format('window is %dx%d', api.nvim_win_get_height(cur), api.nvim_win_get_width(cur)))
end

local LINE = {
  SHORT = function(i) return 'line ' .. i end,
  IND = function(i) return (' '):rep((i % 4) * 2) .. 'line ' .. i end,
  WRAP = function(i) return i % 3 == 0 and (('w'):rep(290) .. ' ' .. i) or ('short ' .. i) end,
  FOLDS = function(i)
    local o = (i - 1) % 12
    return o == 0 and ('h ' .. i .. ' {{{') or o == 8 and '}}}' or ('b ' .. i)
  end,
  LONGSHORT = function(i) return i % 2 == 0 and (('L'):rep(200) .. ' ' .. i) or ('s' .. i) end,
}

local FIXTURES = {
  SHORT = { n = 10000, line = LINE.SHORT },
  IND = { n = 10000, line = LINE.IND },
  WRAP = { n = 5000, line = LINE.WRAP, set = 'wrap' },
  WRAPSS = { n = 5000, line = LINE.WRAP, set = 'wrap smoothscroll' },
  FOLDS = { n = 10000, line = LINE.FOLDS, set = 'foldmethod=marker foldenable foldlevel=0' },
  VLINES = { n = 3000, line = LINE.SHORT, vlines = true },
  LONGSHORT = { n = 2000, line = LINE.LONGSHORT },
  BIG = { n = 100000, line = LINE.SHORT },
}

local line_cache = {}

function H.lines(name, n)
  local f = assert(FIXTURES[name], 'unknown fixture ' .. name)
  n = n or f.n
  local key = name .. ':' .. n
  if not line_cache[key] then
    local t = {}
    for i = 1, n do t[i] = f.line(i) end
    line_cache[key] = t
  end
  return line_cache[key]
end

function H.fixture(name, n)
  local f = assert(FIXTURES[name], 'unknown fixture ' .. name)
  local buf = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(buf, 0, -1, false, H.lines(name, n))
  if f.set then vim.cmd('setlocal ' .. f.set) end
  if f.vlines then
    for i = 6, api.nvim_buf_line_count(buf), 6 do
      api.nvim_buf_set_extmark(buf, NS_VLINES, i - 1, 0, { virt_lines = H.VIRT_LINES, virt_lines_above = true })
    end
  end
  return buf
end

function H.diff_fixture()
  local a = api.nvim_get_current_buf()
  local la = H.lines('SHORT', 2000)
  api.nvim_buf_set_lines(a, 0, -1, false, la)
  local lb = {}
  for i, l in ipairs(la) do
    lb[#lb + 1] = l
    if i == 300 then for k = 1, 6 do lb[#lb + 1] = 'extra 300.' .. k end end
    if i == 900 then for k = 1, 3 do lb[#lb + 1] = 'extra 900.' .. k end end
  end
  local b = api.nvim_create_buf(true, true)
  api.nvim_buf_set_lines(b, 0, -1, false, lb)
  local wa = api.nvim_get_current_win()
  vim.cmd('rightbelow vsplit')
  local wb = api.nvim_get_current_win()
  api.nvim_win_set_buf(wb, b)
  for _, w in ipairs({ wb, wa }) do
    api.nvim_set_current_win(w)
    vim.cmd('diffthis')
    vim.cmd('normal! zR')
    vim.cmd('setlocal noscrollbind nocursorbind')
  end
  return wa, wb
end

local function fold_start(l)
  local s = fn.foldclosed(l)
  return s > 0 and s or l
end

-- Start states: 'MID', 'TOP', 'END', 'NEAR_EOF' or an explicit winrestview() dict.
function H.start(s)
  if s == 'END' then
    vim.cmd('normal! G')
    return
  end
  local n = api.nvim_buf_line_count(0)
  local v = s == 'MID' and { topline = 1000, lnum = 1010 }
    or s == 'TOP' and { topline = 1, lnum = 1 }
    or s == 'NEAR_EOF' and { topline = n - 40, lnum = n - 30 }
    or vim.deepcopy(s)
  if vim.wo.foldenable then
    v.topline = fold_start(v.topline)
    v.lnum = fold_start(v.lnum)
  end
  fn.winrestview(v)
end

-- A prepare function: fixture `name` with o.n lines, global 'scrolloff' o.so, 'startofline' if o.sol,
-- then start state o.start (default MID).
function H.prep(name, o)
  o = o or {}
  return function()
    H.fixture(name, o.n)
    if o.so then vim.o.scrolloff = o.so end
    if o.sol then vim.o.startofline = true end
    H.start(o.start or 'MID')
  end
end

-- Scenarios: the same fixture, start state, inputs and timings, once with the plugin and once as
-- the native reference (plugin mappings removed).
--
-- spec fields (a `native_<field>` variant overrides <field> in the reference run):
--   opts      setup() options (default {}; the reference defaults to H.NATIVE)
--   prepare   function(c): fixture, windows and start state
--   arm       function(c): runs after the start state has been drawn (reactors, counters, mappings)
--   steps     list: string = nvim_input, number = sleep ms, function(c) = call, H.mouse(...) = mouse
--             input, H.fast(...) = typing from a timer, H.SETTLE = settle and capture a checkpoint
--             (an implicit one ends the list)
--   after     function(c): runs after the last checkpoint; values stored in c.x are compared
--   native    false to skip the reference run

function H.mouse(button, action, row, col, mod)
  return { mouse = { button, action, mod or '', 0, row, col } }
end

-- Types `keys` ms from now from a uv timer callback, without waiting: scheduled callbacks (and so
-- the driver) do not run while a typed count is pending.
function H.fast(ms, keys) return { fast = { ms, keys } } end

function H.rep(key, times, gap)
  local s = {}
  for i = 1, times do
    if i > 1 then s[#s + 1] = gap end
    s[#s + 1] = key
  end
  return s
end

function H.play(spec, native)
  local function pick(k)
    local nk = spec['native_' .. k]
    if native and nk ~= nil then return nk end
    return spec[k]
  end
  H.reset()
  H.setup(native and (spec.native_opts or H.NATIVE) or spec.opts or {})
  local c = { x = {}, native = native }
  pick('prepare')(c)
  H.sleep(START_MS)
  local arm = pick('arm')
  if arm then arm(c) end
  local res = { cps = {}, segs = {}, marks = {}, c = c, settled = true }
  start_sampler(api.nvim_get_current_win())
  local from
  local function checkpoint()
    local ok, quiet = H.settle()
    res.settled = res.settled and ok
    res.cps[#res.cps + 1] = H.capture()
    res.segs[#res.segs + 1] = { from = from or #smp.rec, to = #smp.rec, quiet = quiet }
    from = nil
  end
  local steps = pick('steps')
  for _, s in ipairs(steps) do
    if type(s) == 'number' then
      H.sleep(s)
    elseif s == H.SETTLE then
      checkpoint()
    elseif type(s) == 'table' and s.fast then
      local timer = uv.new_timer()
      timer:start(s.fast[1], 0, function()
        timer:close()
        api.nvim_input(s.fast[2])
      end)
    else
      H.sample()
      local m = { t = H.now(), idx = #smp.rec }
      from = from or m.idx
      res.marks[#res.marks + 1] = m
      if type(s) == 'string' then
        api.nvim_input(s)
      elseif type(s) == 'function' then
        s(c)
      else
        api.nvim_input_mouse(unpack(s.mouse))
      end
    end
  end
  if steps[#steps] ~= H.SETTLE then checkpoint() end
  local after = pick('after')
  if after then after(c) end
  stop_sampler()
  res.rec, res.keys, res.anim_ever, res.last_anim = smp.rec, smp.keys, smp.anim_ever, smp.last_anim
  res.x = c.x
  return res
end

function H.scenario(spec)
  local r = { plugin = H.play(spec, false) }
  if spec.native ~= false then r.native = H.play(spec, true) end
  return r
end

-- Record analysis.

function H.frames(res, seg)
  local s = res.segs[seg or 1]
  return s.to - s.from
end

-- Records from mark i (the state just before that input) to the end.
function H.records(res, i)
  local from = math.max(res.marks[i or 1].idx, 1)
  local out = {}
  for k = from, #res.rec do out[#out + 1] = res.rec[k] end
  return out
end

function H.reversals(res, field, i)
  local rec = H.records(res, i)
  local n, sign = 0, 0
  for k = 2, #rec do
    local d = rec[k][field] - rec[k - 1][field]
    if d ~= 0 then
      local sg = d > 0 and 1 or -1
      if sign ~= 0 and sg ~= sign then n = n + 1 end
      sign = sg
    end
  end
  return n
end

function H.first_change_ms(res, i)
  local m = res.marks[i or 1]
  local r = res.rec[m.idx + 1]
  return r and (r.t - m.t)
end

function H.key_time(res, typed, nth)
  local k = 0
  for _, e in ipairs(res.keys) do
    if e.typed == typed then
      k = k + 1
      if k == (nth or 1) then return e.t end
    end
  end
end

function H.checkhealth(name)
  -- Unsilenced, the progress text goes to stderr without a newline and runs into the next result line.
  vim.cmd('silent checkhealth ' .. name)
  local buf = api.nvim_get_current_buf()
  local text = H.buffer_text(buf)
  api.nvim_buf_delete(buf, { force = true })
  return text
end

-- Tests.

local Test = {}
Test.__index = Test

function Test:fail(msg) self.fails[#self.fails + 1] = msg end

function Test:expect(cond, fmt, ...)
  if not cond then self:fail(string.format(fmt, ...)) end
  return cond
end

function Test:parity(r, label)
  self.cases = self.cases + 1
  local p, n = r.plugin, r.native
  local d = {}
  if not p.settled then d[#d + 1] = 'stuck (plugin run)' end
  if not n.settled then d[#d + 1] = 'stuck (native run)' end
  for i = 1, math.max(#p.cps, #n.cps) do
    for _, s in ipairs(H.diff(p.cps[i] or {}, n.cps[i] or {})) do
      d[#d + 1] = (#p.cps > 1 and ('cp' .. i .. ' ') or '') .. s
    end
  end
  for _, s in ipairs(H.diff(p.x, n.x)) do d[#d + 1] = 'x.' .. s end
  if #d > 0 then self:fail((label and (label .. ': ') or '') .. table.concat(d, ', ')) end
  return #d == 0
end

function Test:settled(res, label)
  return self:expect(res.settled, '%sstuck', label and (label .. ': ') or '')
end

function H.test(id, name, body) H.tests[#H.tests + 1] = { id = id, name = name, body = body } end

function H.residual(id, name, body)
  H.tests[#H.tests + 1] = { id = id, name = name, body = body, residual = true }
end

local function detail(t)
  local d = {}
  for i = 1, math.min(#t.fails, MAX_DETAIL) do d[#d + 1] = t.fails[i] end
  if #t.fails > MAX_DETAIL then d[#d + 1] = string.format('(+%d more)', #t.fails - MAX_DETAIL) end
  local s = one_line(table.concat(d, '; '))
  if t.cases > 1 then s = s .. string.format(' [%d/%d cases failed]', #t.fails, t.cases) end
  return s
end

function H.main(filter)
  co = coroutine.create(function()
    local counts = { ok = 0, FAIL = 0, RESIDUAL = 0 }
    local t_start = H.now()
    for _, tc in ipairs(H.tests) do
      if not filter or (tc.id .. ' ' .. tc.name):find(filter) then
        current = tc
        local t0 = H.now()
        local t = setmetatable({ fails = {}, cases = 0 }, Test)
        local ok, err = xpcall(function()
          H.reset()
          tc.body(t)
        end, debug.traceback)
        if not ok then t:fail('error: ' .. err) end
        local cok, cerr = xpcall(H.cleanup, debug.traceback)
        if not cok then t:fail('cleanup: ' .. cerr) end
        local status = tc.residual and 'RESIDUAL' or (#t.fails == 0 and 'ok' or 'FAIL')
        counts[status] = counts[status] + 1
        local d
        if #t.fails > 0 then
          d = detail(t)
        elseif tc.residual then
          d = '== native'
        elseif t.cases > 1 then
          d = string.format('[%d cases]', t.cases)
        end
        local secs = (H.now() - t0) / 1000
        if secs >= SLOW_S then d = (d and (d .. ' ') or '') .. string.format('(%.1f s)', secs) end
        H.out(status .. ' ' .. tc.id .. ' ' .. tc.name .. (d and (' ' .. d) or ''))
        if H.VERBOSE and #t.fails > MAX_DETAIL then
          for _, f in ipairs(t.fails) do H.out('#   ' .. one_line(f)) end
        end
      end
    end
    current = nil
    H.out(string.format('# summary: %d ok, %d FAIL, %d RESIDUAL (%.1f s)', counts.ok, counts.FAIL, counts.RESIDUAL,
      (H.now() - t_start) / 1000))
    vim.cmd(counts.FAIL > 0 and 'cquit 1' or 'qa!')
  end)
  -- Scheduled callbacks do not run while a typed count or operator is pending, so the watchdog
  -- reports from the timer callback and types <C-\><C-N> to let the scheduled cquit run.
  local watchdog = uv.new_timer()
  watchdog:start(1000, 1000, function()
    if H.now() - last_progress > STALL_MS then
      watchdog:stop()
      report_abort('no progress for ' .. STALL_MS .. ' ms')
      api.nvim_input('<C-\\><C-N>')
      vim.schedule(function() vim.cmd('cquit 1') end)
    end
  end)
  vim.schedule(resume)
end

return H
