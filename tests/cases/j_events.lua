local H = ...
local api, fn = vim.api, vim.fn
local S = require('smoothie')
local prep = H.prep

local MIN_WINSCROLLED = 3
local HAS_EIW = fn.exists('+eventignorewin') == 1
local QUIET = { quiet = true }
local MID_MS = 100
local INTERRUPT_MS = 40
local API_MS = 150
local ROUND_TRIP_MS = 100
local COPY_MS = 20
local AT_90 = { topline = 90, lnum = 100 }
-- The cursor on the last row: <C-F> puts it on its target in the first frame, the view keeps moving.
local AT_LAST = { topline = 90, lnum = 137 }
local JUMP = { 1030, 0 }
local OTHER_LINES = 100
local CLICK_ROW, CLICK_COL = 10, 2
local RESTORE_GROUP = 'smoothie_restore'
local USER_EIW = { 'WinEnter', 'WinScrolled' }
local PARITY_FIXTURES = { 'SHORT', 'WRAP', 'FOLDS' }
local PARITY_KEYS = { '<C-D>', '<C-U>', '<C-F>', 'zz' }
local KEY_INTERRUPTS = { { 'j' }, { '<Esc>' }, { ':', 20, '<Esc>' } }
local NOAUTOCMD_FLOAT = { relative = 'editor', row = 2, col = 2, width = 40, height = 10, noautocmd = true }

-- Registered only where they apply: a test that returns before checking anything reports ok.
local quiet_test = HAS_EIW and H.test or function() end
local no_quiet_test = HAS_EIW and function() end or H.test

H.test('T66', 'events_per_frame_default', function(t)
  local r = H.scenario({
    native = false,
    prepare = prep('SHORT'),
    arm = function(c)
      c.n = { WinScrolled = 0, CursorMoved = 0, OptionSet = 0 }
      for ev in pairs(c.n) do
        H.au(ev, function() c.n[ev] = c.n[ev] + 1 end)
      end
    end,
    steps = { '<C-D>' },
  }).plugin
  local n = r.c.n
  t:settled(r)
  t:expect(n.WinScrolled >= MIN_WINSCROLLED, 'WinScrolled=%d', n.WinScrolled)
  t:expect(n.OptionSet == 0, 'OptionSet=%d', n.OptionSet)
end)

local function eiw() return api.nvim_get_option_value('eventignorewin', { win = 0, scope = 'local' }) end

local function eiw_global() return api.nvim_get_option_value('eventignorewin', { scope = 'global' }) end

-- A suppression left behind would silence the events of every later test.
local function clear_eiw()
  for _, w in ipairs(api.nvim_list_wins()) do
    api.nvim_win_call(w, function() vim.cmd('noautocmd set eventignorewin=') end)
  end
end

-- Records each WinScrolled as the topline delta of the current window ('other' when only another
-- window scrolled), and counts CursorMoved and OptionSet.
local function count_events(c)
  c.win = api.nvim_get_current_win()
  c.n = { ws = {}, cm = 0, os = 0 }
  H.au('WinScrolled', function()
    local e = vim.v.event[tostring(api.nvim_get_current_win())]
    c.n.ws[#c.n.ws + 1] = e and e.topline or 'other'
  end)
  H.au('CursorMoved', function() c.n.cm = c.n.cm + 1 end)
  H.au('OptionSet', function() c.n.os = c.n.os + 1 end)
  if HAS_EIW then H.on_cleanup(clear_eiw) end
end

local function restart_count(c) c.n.ws, c.n.cm = {}, 0 end

local function events_to_x(c)
  c.x.ws, c.x.cm, c.x.os = table.concat(c.n.ws, ','), c.n.cm, c.n.os
end

local function restorers()
  local ok, list = pcall(api.nvim_get_autocmds, { group = RESTORE_GROUP })
  return ok and #list or 0
end

-- `steps`, then a native scroll and a cursor move in the current window: records the window's
-- 'eventignorewin' and whether their events fire, under prefix `p`.
local function then_native_events(steps, p)
  p = p or ''
  return vim.list_extend(vim.list_extend({}, steps), {
    H.SETTLE,
    function(c)
      c.x[p .. 'eiw'], c.x[p .. 'eiw_global'] = eiw(), eiw_global()
      restart_count(c)
    end,
    '5<C-E>', H.SETTLE,
    function(c)
      c.x[p .. 'ws_next'] = table.concat(c.n.ws, ',')
      restart_count(c)
    end,
    'j', H.SETTLE,
    function(c) c.x[p .. 'cm_next'] = c.n.cm end,
  })
end

local function with_idle(steps)
  steps[#steps + 1] = function(c) c.x.idle, c.x.os = require('smoothie.engine').idle(), c.n.os end
  return steps
end

-- Appends a record of what the plugin left behind.
local function with_leftovers(steps)
  steps[#steps + 1] = function(c) c.x.restorers = restorers() end
  return with_idle(steps)
end

-- Compares only the recorded values: these scenarios leave the plugin's view where native's is not.
local function x_parity(t, r, label)
  t.cases = t.cases + 1
  local d = H.diff(r.plugin.x, r.native.x)
  if not r.plugin.settled then d[#d + 1] = 'stuck (plugin run)' end
  if not r.native.settled then d[#d + 1] = 'stuck (native run)' end
  if #d > 0 then t:fail((label and (label .. ': ') or '') .. table.concat(d, ', ')) end
end

local function mid_probe(c) c.mid = { S.is_animating(), #c.n.ws, c.n.cm } end

-- The plugin run was animating without events when mid_probe ran, so there was something to restore.
local function expect_suppressed(t, r, label)
  local anim, ws, cm = unpack(r.plugin.c.mid)
  label = label and (label .. ': ') or ''
  t:expect(anim, '%snot animating at the probe', label)
  t:expect(ws == 0 and cm == 0, '%swhile animating: WinScrolled=%d CursorMoved=%d', label, ws, cm)
end

local function scratch_buf(n)
  local b = api.nvim_create_buf(true, true)
  api.nvim_buf_set_lines(b, 0, -1, false, H.lines('SHORT', n))
  return b
end

local function two_buffers(c)
  c.a = H.fixture('SHORT')
  c.b = scratch_buf(OTHER_LINES)
  H.start(AT_90)
end

-- The top window shows buffer a, which animates; the bottom one shows buffer b.
local function a_over_b(c)
  c.b = api.nvim_get_current_buf()
  api.nvim_buf_set_lines(c.b, 0, -1, false, H.lines('SHORT', OTHER_LINES))
  c.a = scratch_buf()
  vim.cmd('aboveleft split')
  api.nvim_win_set_buf(0, c.a)
  H.start(AT_90)
end

quiet_test('T116', 'quiet_one_winscrolled_cumulative', function(t)
  local r = H.scenario({
    opts = QUIET,
    prepare = prep('SHORT'),
    arm = count_events,
    steps = { '<C-D>', MID_MS, mid_probe },
    after = events_to_x,
  })
  t:parity(r)
  expect_suppressed(t, r)
end)

quiet_test('T117', 'quiet_chain_single_event', function(t)
  local r = H.scenario({
    opts = QUIET,
    prepare = prep('SHORT'),
    arm = count_events,
    steps = H.rep('<C-D>', 3, 15),
    after = function(c)
      local total = 0
      for _, d in ipairs(c.n.ws) do total = total + d end
      c.x.ws_total, c.x.os = total, c.n.os
    end,
  })
  t:parity(r)
  local n = r.plugin.c.n
  t:expect(#n.ws == 1 and n.cm == 1, 'WinScrolled=[%s] CursorMoved=%d, want one of each', table.concat(n.ws, ','), n.cm)
end)

quiet_test('T118', 'quiet_restores_value_no_optionset', function(t)
  for _, user in ipairs(USER_EIW) do
    t:parity(H.scenario({
      opts = QUIET,
      prepare = function()
        prep('SHORT')()
        vim.cmd('setlocal eventignorewin=' .. user)
      end,
      arm = count_events,
      steps = { '<C-D>' },
      after = function(c)
        events_to_x(c)
        c.x.eiw, c.x.eiw_global = eiw(), eiw_global()
      end,
    }), user)
  end
end)

-- <C-D>, and `...` while it animates.
local function interrupted(...)
  return vim.list_extend({ '<C-D>', INTERRUPT_MS, mid_probe }, { ... })
end

quiet_test('T119', 'quiet_noautocmd_buffer_switch_no_leak', function(t)
  local steps = then_native_events(interrupted(function(c) vim.cmd('noautocmd buffer ' .. c.b) end), 'b.')
  steps[#steps + 1] = function(c) vim.cmd('buffer ' .. c.a) end
  local r = H.scenario({
    opts = QUIET,
    prepare = two_buffers,
    arm = count_events,
    steps = with_leftovers(then_native_events(steps, 'a.')),
  })
  x_parity(t, r)
  expect_suppressed(t, r)
end)

H.test('T120', 'quiet_landing_parity', function(t)
  for _, f in ipairs(PARITY_FIXTURES) do
    for _, key in ipairs(PARITY_KEYS) do
      t:parity(H.scenario({
        opts = QUIET,
        prepare = prep(f),
        arm = count_events,
        steps = { key },
        after = HAS_EIW and events_to_x or nil,
      }), f .. ' ' .. key)
    end
  end
end)

quiet_test('T121', 'quiet_key_interrupt_restores', function(t)
  for _, keys in ipairs(KEY_INTERRUPTS) do
    local steps = interrupted(unpack(keys))
    vim.list_extend(steps, { H.SETTLE, function(c) c.x.ws_first = table.concat(c.n.ws, ',') end })
    local label = table.concat(keys)
    local r = H.scenario({
      opts = QUIET,
      prepare = prep('SHORT', { start = AT_90 }),
      arm = count_events,
      steps = with_leftovers(then_native_events(steps)),
    })
    t:parity(r, label)
    expect_suppressed(t, r, label)
  end
end)

no_quiet_test('T122', 'quiet_unsupported_is_noop', function(t)
  local ok, err = pcall(S.setup, QUIET)
  t:expect(ok, 'setup{quiet=true} raised: %s', tostring(err))
  if not ok then return end
  local r = H.scenario({ opts = QUIET, prepare = prep('SHORT'), arm = count_events, steps = { '<C-D>' } })
  t:parity(r)
  local n = r.plugin.c.n
  t:expect(#n.ws >= MIN_WINSCROLLED, 'WinScrolled=%d, want one per frame', #n.ws)
  t:expect(n.os == 0, 'OptionSet=%d', n.os)
end)

local function fault_on_second_frame(c)
  count_events(c)
  local calls = 0
  require('smoothie.engine')._fault = function()
    calls = calls + 1
    if calls == 2 then error('injected frame fault') end
  end
end

local EXITS = {
  { 'stop()', function() S.stop() end },
  { 'external cursor jump', function() api.nvim_win_set_cursor(0, { 700, 0 }) end },
  { 'resize', function() vim.cmd('resize 20') end },
  { 'BufLeave', function(c) vim.cmd('buffer ' .. c.b) end, 60, function(c) vim.cmd('buffer ' .. c.a) end },
  { 'mouse click', H.mouse('left', 'press', CLICK_ROW, CLICK_COL), H.mouse('left', 'release', CLICK_ROW, CLICK_COL) },
  { 'startinsert', function() vim.cmd('startinsert') end, H.SETTLE, '<Esc>' },
  { 'paste', function() api.nvim_paste('PASTED', false, -1) end },
  { 'background window', split = true, function() vim.cmd('noautocmd wincmd w') end, H.SETTLE,
    function(c) api.nvim_set_current_win(c.win) end },
}

quiet_test('T124', 'quiet_exit_paths_restore', function(t)
  local function run(label, steps, arm, split)
    local r = H.scenario({
      opts = QUIET,
      prepare = function(c)
        two_buffers(c)
        vim.o.mouse = 'a'
        if split then
          vim.cmd('split')
          H.start(AT_90)
        end
      end,
      arm = arm,
      native_arm = count_events,
      steps = with_leftovers(then_native_events(steps)),
    })
    x_parity(t, r, label)
    return r
  end
  for _, e in ipairs(EXITS) do
    expect_suppressed(t, run(e[1], interrupted(unpack(e, 2)), count_events, e.split), e[1])
  end
  run('frame error', { '<C-D>' }, fault_on_second_frame)
end)

-- Closing a window saves its options into the buffer's window info (close_buffer ->
-- buflist_setfpos with copy_options), and :buffer in a window that never showed that buffer copies
-- them from there (get_winopts -> find_wininfo).
quiet_test('T125', 'quiet_window_closed_no_leak', function(t)
  local r = H.scenario({
    opts = QUIET,
    prepare = a_over_b,
    arm = count_events,
    steps = with_leftovers(then_native_events(vim.list_extend(
      interrupted(function() api.nvim_win_close(0, true) end),
      { H.SETTLE, function(c) vim.cmd('buffer ' .. c.a) end }))),
  })
  x_parity(t, r)
  expect_suppressed(t, r)
end)

-- After a noautocmd switch, the window info saved for the first window is what :buffer copies into
-- a window that never showed the buffer (find_wininfo), and back into the first window later.
quiet_test('T126', 'quiet_noautocmd_switch_other_window_no_leak', function(t)
  local steps = then_native_events(vim.list_extend(
    interrupted(function(c) vim.cmd('noautocmd buffer ' .. c.b) end),
    {
      H.SETTLE,
      function(c)
        c.w1 = api.nvim_get_current_win()
        vim.cmd('split')
        vim.cmd('buffer ' .. c.a)
      end,
    }), 'other.')
  steps[#steps + 1] = function(c)
    api.nvim_set_current_win(c.w1)
    vim.cmd('buffer ' .. c.a)
  end
  local r = H.scenario({
    opts = QUIET,
    prepare = two_buffers,
    arm = count_events,
    steps = with_leftovers(then_native_events(steps, 'same.')),
  })
  x_parity(t, r)
  expect_suppressed(t, r)
end)

-- A window made without autocmds (no WinNew) copies the options of the window it is made from when
-- it shows the same buffer (win_init).
local NOAUTOCMD_WINDOWS = {
  { 'float', function(c) c.copy = api.nvim_open_win(0, false, NOAUTOCMD_FLOAT) end },
  { 'split', function(c)
    vim.cmd('noautocmd split')
    c.copy = api.nvim_get_current_win()
  end },
}

quiet_test('T128', 'quiet_noautocmd_window_no_leak', function(t)
  for _, w in ipairs(NOAUTOCMD_WINDOWS) do
    local steps = then_native_events(vim.list_extend(interrupted(w[2]), {
      H.SETTLE,
      function(c) api.nvim_set_current_win(c.copy) end,
    }), 'copy.')
    steps[#steps + 1] = function(c) api.nvim_set_current_win(c.win) end
    local r = H.scenario({
      opts = QUIET,
      prepare = prep('SHORT', { start = AT_90 }),
      arm = count_events,
      steps = with_leftovers(then_native_events(steps, 'orig.')),
    })
    x_parity(t, r, w[1])
    expect_suppressed(t, r, w[1])
  end
end)

-- A new window copies the options of the window it is split from (win_init).
quiet_test('T127', 'quiet_split_no_leak', function(t)
  local steps = then_native_events(interrupted(function() vim.cmd('split') end), 'new.')
  steps[#steps + 1] = function(c) api.nvim_set_current_win(c.win) end
  local r = H.scenario({
    opts = QUIET,
    prepare = prep('SHORT', { start = AT_90 }),
    arm = count_events,
    steps = with_leftovers(then_native_events(steps, 'split.')),
  })
  x_parity(t, r)
  expect_suppressed(t, r)
end)

-- A cursor move, then in the same callback a scroll that keeps the cursor where it is.
local function move_then(key, plugin)
  return function()
    api.nvim_win_set_cursor(0, JUMP)
    if plugin then
      S.scroll(key)
    else
      vim.cmd('normal! ' .. key)
    end
  end
end

local function map_move_then(key, plugin)
  return function(c)
    count_events(c)
    H.map('n', 'X', move_then(key, plugin))
  end
end

quiet_test('T129', 'quiet_move_before_scroll_fires_cursormoved', function(t)
  for _, key in ipairs({ 'zz', 'zt' }) do
    t:parity(H.scenario({
      opts = QUIET,
      prepare = prep('SHORT'),
      arm = count_events,
      steps = { move_then(key, true) },
      native_steps = { move_then(key, false) },
      after = events_to_x,
    }), 'scroll ' .. key)
  end
  t:parity(H.scenario({
    opts = QUIET,
    prepare = prep('SHORT'),
    arm = map_move_then('zz', true),
    native_arm = map_move_then('zz', false),
    steps = { 'X' },
    after = events_to_x,
  }), 'mapping zz')
end)

local LANDINGS_WITHOUT_KEY = {
  { 'stop()', function() S.stop() end },
  { 'scroll() that does not animate', function()
    vim.w.smoothie_enabled = false
    S.scroll('zt')
  end },
}

quiet_test('T130', 'quiet_landing_without_key_fires_cursormoved', function(t)
  for _, l in ipairs(LANDINGS_WITHOUT_KEY) do
    t:parity(H.scenario({
      opts = QUIET,
      prepare = prep('SHORT', { start = AT_LAST }),
      arm = count_events,
      steps = { '<C-F>', API_MS, l[2] },
      after = events_to_x,
    }), l[1])
  end
end)

-- A window closed keeps its entry in the buffer's window info (win_free()), and a window with no
-- saved options of its own for the buffer copies it (find_wininfo()): every later display does.
local CLOSES = {
  { 'noautocmd close', function() vim.cmd('noautocmd close') end },
  { 'noautocmd buffer, then close', function(c) vim.cmd('noautocmd buffer ' .. c.b) end, H.SETTLE,
    function() vim.cmd('close') end },
}

quiet_test('T131', 'quiet_closed_window_no_leak_into_later_windows', function(t)
  for _, e in ipairs(CLOSES) do
    local steps = then_native_events(vim.list_extend(interrupted(unpack(e, 2)), {
      H.SETTLE,
      function(c) vim.cmd('buffer ' .. c.a) end,
    }), 'first.')
    steps[#steps + 1] = function(c)
      vim.cmd('new')
      vim.cmd('buffer ' .. c.a)
    end
    local r = H.scenario({
      opts = QUIET,
      prepare = a_over_b,
      arm = count_events,
      -- Not with_leftovers(): the restorer outlives the closed window, until the buffer is wiped out.
      steps = with_idle(then_native_events(steps, 'fresh.')),
    })
    x_parity(t, r, e[1])
    expect_suppressed(t, r, e[1])
  end
end)

quiet_test('T132', 'quiet_noautocmd_round_trip_no_leak', function(t)
  local steps = interrupted(function(c) vim.cmd('noautocmd buffer ' .. c.b) end, ROUND_TRIP_MS,
    function(c) vim.cmd('noautocmd buffer ' .. c.a) end)
  local r = H.scenario({
    opts = QUIET,
    prepare = two_buffers,
    arm = count_events,
    steps = with_leftovers(then_native_events(steps)),
  })
  x_parity(t, r)
  expect_suppressed(t, r)
end)

-- A window made without autocmds on the animated buffer copies the animated window's options
-- (win_init()), and leaving the buffer or closing saves them for its next display (buflist_setfpos()).
local function open_copy(c) c.copy = api.nvim_open_win(c.a, false, NOAUTOCMD_FLOAT) end

local COPY_LEAVES = {
  { 'switch', function(c) api.nvim_win_set_buf(c.copy, c.b) end, function(c)
    api.nvim_win_set_buf(c.copy, c.a)
    api.nvim_set_current_win(c.copy)
  end },
  { 'close', function(c) api.nvim_win_close(c.copy, true) end, function(c)
    vim.cmd('new')
    vim.cmd('buffer ' .. c.a)
  end },
}

quiet_test('T133', 'quiet_copy_leaving_buffer_no_leak', function(t)
  for _, e in ipairs(COPY_LEAVES) do
    local steps = then_native_events(interrupted(open_copy, COPY_MS, e[2], H.SETTLE, e[3]))
    steps[#steps + 1] = function(c) api.nvim_set_current_win(c.win) end
    local r = H.scenario({
      opts = QUIET,
      prepare = two_buffers,
      arm = count_events,
      steps = with_leftovers(steps),
    })
    x_parity(t, r, e[1])
    expect_suppressed(t, r, e[1])
  end
end)

local EIW_EDITS = {
  { 'set', function() vim.cmd('noautocmd setlocal eventignorewin=WinEnter') end },
  { 'append', function() vim.cmd('setlocal eventignorewin+=WinEnter') end },
  { 'remove', function() vim.cmd('setlocal eventignorewin-=CursorMoved') end },
  { 'vim.wo save and restore', function()
    local keep = vim.wo.eventignorewin
    vim.wo.eventignorewin = 'all'
    vim.wo.eventignorewin = keep
  end },
}

quiet_test('T134', 'quiet_value_changed_during_animation_keeps_change', function(t)
  for _, e in ipairs(EIW_EDITS) do
    local r = H.scenario({
      opts = QUIET,
      prepare = prep('SHORT', { start = AT_90 }),
      arm = count_events,
      steps = with_leftovers(then_native_events(interrupted(e[2]))),
    })
    x_parity(t, r, e[1])
    expect_suppressed(t, r, e[1])
  end
end)

-- The key chained into <C-F> keeps the cursor where <C-F> put it in its first frame: only the
-- chain's start shows that the cursor moved.
quiet_test('T135', 'quiet_chain_after_cursor_target_fires_cursormoved', function(t)
  for _, key in ipairs({ 'zt', 'zz', 'zb' }) do
    t:parity(H.scenario({
      opts = QUIET,
      prepare = prep('SHORT', { start = AT_LAST }),
      arm = count_events,
      steps = { '<C-F>', MID_MS, key },
      after = function(c) c.x.cm, c.x.os = c.n.cm, c.n.os end,
    }), key)
  end
end)

quiet_test('T136', 'quiet_split_to_other_buffer_no_leak', function(t)
  local steps = then_native_events(vim.list_extend(interrupted(function(c)
    vim.cmd('split')
    c.x.new_mid = eiw()
    vim.cmd('buffer ' .. c.b)
  end), { H.SETTLE, function(c) vim.cmd('buffer ' .. c.a) end }), 'new.')
  steps[#steps + 1] = function(c) api.nvim_set_current_win(c.win) end
  local r = H.scenario({
    opts = QUIET,
    prepare = two_buffers,
    arm = count_events,
    steps = with_leftovers(then_native_events(steps, 'orig.')),
  })
  x_parity(t, r)
  expect_suppressed(t, r)
end)
