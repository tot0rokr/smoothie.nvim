local H = ...
local prep = H.prep

local AT_90 = { topline = 90, lnum = 100 }

H.test('T24', 'three_ctrl_d_15ms', function(t)
  local r = H.scenario({ prepare = prep('SHORT'), steps = H.rep('<C-D>', 3, 15) })
  t:parity(r)
  t:expect(H.reversals(r.plugin, 'top') == 0 and H.reversals(r.plugin, 'lnum') == 0, 'reversals top=%d lnum=%d',
    H.reversals(r.plugin, 'top'), H.reversals(r.plugin, 'lnum'))
end)

H.test('T25', 'ten_ctrl_d_8ms', function(t)
  t:parity(H.scenario({ prepare = prep('SHORT'), steps = H.rep('<C-D>', 10, 8) }))
end)

H.test('T26', 'ctrl_d_then_ctrl_u_returns', function(t)
  local r = H.scenario({ prepare = prep('SHORT', { start = AT_90 }), steps = { '<C-D>', 60, '<C-U>' } })
  t:parity(r)
  local c = r.plugin.cps[1]
  t:expect(c.topline == 90 and c.lnum == 100, 'top=%d lnum=%d, want 90/100', c.topline, c.lnum)
end)

H.test('T27', 'ctrl_d_then_zz_centres_target', function(t)
  t:parity(H.scenario({ prepare = prep('SHORT', { start = AT_90 }), steps = { '<C-D>', 50, 'zz' } }))
end)

H.test('T28', 'ctrl_f_then_counted_ctrl_b', function(t)
  t:parity(H.scenario({ prepare = prep('SHORT'), steps = { '<C-F>', 40, '3<C-B>' } }))
end)

H.test('T29', 'folds_5x_ctrl_d_10ms', function(t)
  t:parity(H.scenario({ prepare = prep('FOLDS'), steps = H.rep('<C-D>', 5, 10) }))
end)

H.test('T30', 'hold_no_jump_no_reversal', function(t)
  local r = H.scenario({ prepare = prep('SHORT'), steps = H.rep('<C-D>', 10, 30) })
  t:parity(r)
  local rec = H.records(r.plugin)
  for k = 2, #rec do
    local d = rec[k].top - rec[k - 1].top
    t:expect(d >= 0 and d <= H.HEIGHT, 'topline step %d -> %d', rec[k - 1].top, rec[k].top)
  end
end)

H.test('T31', 'count_mid_animation', function(t)
  local r = H.scenario({ prepare = prep('SHORT'), steps = { '<C-D>', 40, '3', H.fast(10, '<C-D>') } })
  t:parity(r)
  t:expect(r.plugin.cps[1].scroll == 3, '&l:scroll=%d', r.plugin.cps[1].scroll)
end)

H.test('T32', 'noop_chained_key_continues', function(t)
  local r = H.scenario({ prepare = prep('SHORT', { n = 2000, start = 'NEAR_EOF' }), steps = { '<C-F>', 30, '<C-F>' } })
  t:parity(r)
  local rec = H.records(r.plugin, 2)
  local remaining = math.abs(r.plugin.cps[1].topline - rec[1].top)
  for k = 2, #rec do
    local d = math.abs(rec[k].top - rec[k - 1].top)
    t:expect(d <= remaining / 2, 'jump of %d rows with %d remaining at the second key', d, remaining)
  end
  t:expect(#rec - 1 >= 2, 'records after the second key=%d', #rec - 1)
end)

local HOLD_PRESSES = 30
local HOLD_FROM_EOF = 300

local function topline_rises(res)
  local rec, n = H.records(res), 0
  for k = 2, #rec do
    if rec[k].top < rec[k - 1].top then n = n + 1 end
  end
  return n
end

H.test('T106', 'held_key_never_scrolls_back', function(t)
  for _, case in ipairs({
    { 'WRAP', 1500, 0, '<C-D>', 16 },
    { 'WRAP', 1500, 0, '<C-F>', 16 },
    { 'WRAP', 1500, 0, '<C-F>', 33 },
    { 'SHORT', 2000, 5, '<C-F>', 16 },
    { 'VLINES', 2000, 5, '<C-F>', 16 },
    { 'WRAPSS', 1500, 5, '<C-F>', 16 },
  }) do
    local f, n, so, key, gap = unpack(case)
    local label = string.format('%s so=%d %s @%d', f, so, key, gap)
    local start = { topline = n - HOLD_FROM_EOF, lnum = n - HOLD_FROM_EOF + 10 }
    local r = H.scenario({ prepare = prep(f, { n = n, so = so, start = start }), steps = H.rep(key, HOLD_PRESSES, gap) })
    t:parity(r, label)
    local up = topline_rises(r.plugin)
    t:expect(up == 0, '%s: topline went back %d times', label, up)
  end
end)

H.test('T107', 'one_row_wrap_window_no_reversal', function(t)
  for _, key in ipairs({ '<C-F>', '<S-Down>' }) do
    local r = H.scenario({
      prepare = function()
        H.fixture('WRAP')
        vim.cmd('split')
        vim.cmd('resize 1')
        H.start({ topline = 99, lnum = 99 })
      end,
      steps = { key },
    })
    t:parity(r, key)
    local rt = H.reversals(r.plugin, 'top')
    t:expect(rt == 0, '%s: topline reversals=%d', key, rt)
  end
end)
