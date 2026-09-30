local H = ...
local api = vim.api
local S = require('smoothie')
local prep = H.prep

local AT_90 = { topline = 90, lnum = 100 }

H.test('T81', 'smoothie_do_raw_keys', function(t)
  for _, case in ipairs({ { 'Q', [[<Cmd>call smoothie#do("\<C-D>")<CR>]], '<C-D>' },
    { 'P', [[<Cmd>call smoothie#do("\<PageDown>")<CR>]], '<PageDown>' } }) do
    local lhs, rhs, key = case[1], case[2], case[3]
    local r = H.scenario({
      prepare = prep('SHORT'),
      arm = function() H.map('n', lhs, rhs) end,
      native_arm = false,
      steps = { lhs },
      native_steps = { key },
    })
    t:parity(r, key)
    t:expect(H.frames(r.plugin) >= 3, '%s: frames=%d', key, H.frames(r.plugin))
  end
end)

H.test('T82', 'legacy_direction_functions', function(t)
  t:parity(H.scenario({ prepare = prep('SHORT'), steps = { ':call smoothie#forwards()<CR>' }, native_steps = { '<C-F>' } }))
end)

H.test('T83', 'plug_smoothie_G', function(t)
  local r = H.scenario({
    prepare = prep('SHORT'),
    arm = function() H.map('n', 'Q', '<Plug>(Smoothie_G)', { remap = true }) end,
    native_arm = false,
    steps = { 'Q' },
    native_steps = { 'G' },
  })
  t:parity(r)
  t:expect(H.frames(r.plugin) >= 3, 'frames=%d', H.frames(r.plugin))
end)

H.test('T84', 'scroll_api_sequence', function(t)
  local r = H.scenario({
    prepare = prep('SHORT', { start = AT_90 }),
    steps = { function(c) c.ret = S.scroll('<C-d>zz') end },
    native_steps = { function() vim.cmd('normal! ' .. vim.keycode('<C-d>zz')) end },
  })
  t:parity(r)
  t:expect(r.plugin.c.ret == true, 'scroll() returned %s', tostring(r.plugin.c.ret))
end)

H.test('T85', 'scroll_api_other_window', function(t)
  local r = H.scenario({
    prepare = function(c)
      H.fixture('SHORT')
      c.other = api.nvim_get_current_win()
      H.start(AT_90)
      vim.cmd('split')
      c.cur = api.nvim_get_current_win()
      H.start(AT_90)
    end,
    steps = { function(c) S.scroll('<C-d>', { win = c.other }) end },
    native_steps = { function(c) api.nvim_win_call(c.other, function() vim.cmd('normal! \4') end) end },
    after = function(c)
      c.x.other = H.vstr(c.other)
      c.x.cur = H.vstr(c.cur)
      c.x.focus_kept = api.nvim_get_current_win() == c.cur
    end,
  })
  t:parity(r)
  t:expect(r.plugin.x.focus_kept, 'focus moved')
end)

H.test('T86', 'scroll_api_count', function(t)
  local r = H.scenario({
    prepare = prep('SHORT'),
    steps = { function() S.scroll('<C-d>', { count = 3 }) end },
    native_steps = { function() vim.cmd('normal! 3\4') end },
  })
  t:parity(r)
  t:expect(r.plugin.cps[1].scroll == 3, '&l:scroll=%d', r.plugin.cps[1].scroll)
end)

H.test('T87', 'stop_lands_exact', function(t)
  local r = H.scenario({
    prepare = prep('SHORT'),
    steps = { '<C-D>', 30, function(c)
      S.stop()
      c.x.view_after_stop = H.vstr(0)
      c.anim = S.is_animating()
    end },
    native_steps = { '<C-D>', 30, function(c) c.x.view_after_stop = H.vstr(0) end },
  })
  t:parity(r)
  t:expect(r.plugin.c.anim == false, 'still animating after stop()')
end)

H.test('T110', 'scroll_twice_in_one_callback_keeps_count', function(t)
  local function twice()
    S.scroll('<C-d>')
    S.scroll('<C-d>')
  end
  for _, case in ipairs({ { 'Q', '<C-D><C-D>' }, { '3Q', '3<C-D>3<C-D>' } }) do
    local r = H.scenario({
      prepare = prep('SHORT'),
      arm = function() H.map('n', 'Q', twice) end,
      native_arm = false,
      steps = { case[1] },
      native_steps = { case[2] },
    })
    t:parity(r, case[1])
  end
end)

H.test('T111', 'enabled_defaults_to_current_window', function(t)
  H.setup({})
  t:expect(S.enabled() == true, 'enabled() = %s', tostring(S.enabled()))
  vim.w.smoothie_enabled = 0
  t:expect(S.enabled() == false, 'enabled() with w:smoothie_enabled=0 = %s', tostring(S.enabled()))
  vim.w.smoothie_enabled = nil
end)
