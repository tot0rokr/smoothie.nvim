local H = ...
local fn = vim.fn
local prep = H.prep

local JUMPS = { jumps = true }
local LINE_5 = { topline = 1, lnum = 5 }

H.test('T44', 'linewise_visual_extends', function(t)
  local r = H.scenario({ opts = JUMPS, prepare = prep('SHORT'), steps = { 'V<C-D>', H.SETTLE, 'y' } })
  t:parity(r)
  t:expect(r.plugin.cps[1].mode == 'V', 'mode before y=%s', r.plugin.cps[1].mode)
end)

H.test('T45', 'charwise_visual_ctrl_f_yank', function(t)
  t:parity(H.scenario({ opts = JUMPS, prepare = prep('SHORT'), steps = { 'v<C-F>', H.SETTLE, 'y' } }))
end)

H.test('T46', 'blockwise_dollar_yank', function(t)
  t:parity(H.scenario({ opts = JUMPS, prepare = prep('IND'), steps = { '<C-v>$<C-D>', H.SETTLE, 'y' } }))
end)

H.test('T47', 'select_mode_types_G', function(t)
  local r = H.scenario({
    opts = JUMPS,
    prepare = prep('SHORT', { start = LINE_5 }),
    steps = { 'gh', 20, 'G' },
    after = function(c) c.x.line5 = fn.getline(5) end,
  })
  t:parity(r)
  t:expect(r.plugin.x.line5 == 'Gine 5', 'line 5=%q', r.plugin.x.line5)
  t:expect(r.plugin.cps[1].topline == 1, 'topline=%d', r.plugin.cps[1].topline)
end)

H.test('T48', 'select_mode_types_zz', function(t)
  t:parity(H.scenario({ opts = JUMPS, prepare = prep('SHORT', { start = LINE_5 }), steps = { 'gh', 20, 'zzq' } }))
end)

H.test('T49', 'op_pending_ctrl_d_native', function(t)
  for _, key in ipairs({ 'd<C-D>', 'dG' }) do
    local r = H.scenario({
      opts = JUMPS,
      prepare = prep('SHORT'),
      steps = { key },
      after = function(c) c.x.count = fn.line('$') end,
    })
    t:parity(r, key)
    if key == 'd<C-D>' then t:expect(r.plugin.x.count == 10000, 'd<C-D> left %d lines', r.plugin.x.count) end
  end
end)

H.test('T103', 'visual_extends_over_closed_folds', function(t)
  for _, key in ipairs({ 'V<C-D>', 'v<C-D>', '<C-v><C-D>', 'V<C-F>', 'Vjj<C-D>', 'V<C-U>' }) do
    t:parity(H.scenario({ prepare = prep('FOLDS'), steps = { key, H.SETTLE, 'd' } }), key)
  end
end)

H.test('T112', 'counted_visual_scroll_keeps_selection', function(t)
  for _, case in ipairs({ { 'Vjj3<C-D>', 'V' }, { 'vjj3<C-F>', 'v' }, { 'Vjj20j3zt', 'V' } }) do
    local r = H.scenario({ opts = JUMPS, prepare = prep('SHORT'), steps = { case[1], H.SETTLE, 'd' } })
    t:parity(r, case[1])
    t:expect(r.plugin.cps[1].mode == case[2], '%s: mode before d=%s', case[1], r.plugin.cps[1].mode)
  end
end)
