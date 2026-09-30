local H = ...
local api, fn = vim.api, vim.fn
local prep = H.prep

local AT_90 = { topline = 90, lnum = 100 }
-- A 3-row travel takes 50 ms under the motion law and shows 2 rows at frame 0 and 3 at frame 1.
local THREE_ROW_FRAMES = 2

H.test('T38', 'macro_runs_native', function(t)
  local r = H.scenario({
    prepare = function()
      prep('SHORT')()
      fn.setreg('q', vim.keycode('<C-D>dd'))
    end,
    steps = { '@q' },
  })
  t:parity(r)
  t:expect(not r.plugin.anim_ever, 'is_animating() was true during the macro')
end)

H.test('T39', 'normal_without_bang_synchronous', function(t)
  local r = H.scenario({
    prepare = prep('SHORT', { start = AT_90 }),
    steps = { function(c)
      vim.cmd('normal \4')
      c.x.line = fn.line('.')
    end },
  })
  t:parity(r)
  t:expect(r.plugin.x.line == 124, "line('.')=%d right after :normal", r.plugin.x.line)
end)

H.test('T40', 'feedkeys_x_synchronous', function(t)
  local r = H.scenario({
    prepare = prep('SHORT', { start = AT_90 }),
    steps = { function(c)
      api.nvim_feedkeys(vim.keycode('<C-D>3j'), 'x', false)
      c.x.line = fn.line('.')
    end },
  })
  t:parity(r)
  t:expect(r.plugin.x.line == 127, "line('.')=%d right after feedkeys", r.plugin.x.line)
end)

-- The plugin run maps recursively (reaching the plugin's mappings); the reference run does not.
local function user_map(lhs, rhs)
  return function(c) H.map('n', lhs, rhs, { remap = not c.native }) end
end

H.test('T41', 'mapping_tail_instant', function(t)
  local r = H.scenario({ prepare = prep('SHORT', { start = AT_90 }), arm = user_map('Q', '<C-D>zz'), steps = { 'Q' } })
  t:parity(r)
  t:expect(H.reversals(r.plugin, 'top') == 0 and H.reversals(r.plugin, 'lnum') == 0, 'reversals top=%d lnum=%d',
    H.reversals(r.plugin, 'top'), H.reversals(r.plugin, 'lnum'))
end)

H.test('T42', 'plug_via_user_map_animates', function(t)
  local r = H.scenario({
    prepare = prep('SHORT', { start = AT_90 }),
    arm = function() H.map('n', 'Q', '<Plug>(SmoothieDownwards)', { remap = true }) end,
    native_arm = false,
    steps = { '3Q' },
    native_steps = { '3<C-D>' },
  })
  t:parity(r)
  t:expect(H.frames(r.plugin) >= THREE_ROW_FRAMES, 'frames=%d', H.frames(r.plugin))
  t:expect(r.plugin.cps[1].scroll == 3, '&l:scroll=%d', r.plugin.cps[1].scroll)
end)

H.test('T43', 'rhs_count_prefix_runs_instant', function(t)
  local r = H.scenario({ prepare = prep('SHORT', { start = AT_90 }), arm = user_map('X', '5<C-D>'), steps = { 'X' } })
  t:parity(r)
  t:expect(H.frames(r.plugin) <= 1, 'frames=%d', H.frames(r.plugin))
end)

local function with_macro(n, start, keys)
  return function()
    prep('SHORT', { n = n, start = start })()
    fn.setreg('q', vim.keycode(keys))
  end
end

H.test('T99', 'failing_scroll_ends_macro', function(t)
  for _, case in ipairs({
    { '<C-D>x at the end', with_macro(20, 'END', '<C-D>x') },
    { '<C-U>x at the top', with_macro(20, 'TOP', '<C-U>x') },
    { '<C-F> until the end, then ix<Esc>', with_macro(100, 'TOP', ('<C-F>'):rep(6) .. 'ix<Esc>') },
  }) do
    t:parity(H.scenario({ prepare = case[2], steps = { '@q' } }), case[1])
  end
end)

H.test('T100', 'failing_scroll_drops_mapping_tail', function(t)
  t:parity(H.scenario({ prepare = prep('SHORT', { n = 20, start = 'END' }), arm = user_map('Q', '<C-D>x'),
    steps = { 'Q' } }), 'nmap Q <C-D>x')
  t:parity(H.scenario({
    prepare = prep('SHORT', { n = 20, start = 'END' }),
    steps = { function() vim.cmd('normal ' .. vim.keycode('<C-D>x')) end },
  }), ':normal <C-D>x')
end)

H.test('T101', 'search_error_drops_mapping_tail', function(t)
  local function not_found(c)
    prep('SHORT', { n = 20, start = 'TOP' })(c)
    fn.setreg('/', 'zzzz')
    fn.setreg('q', 'nx')
  end
  t:parity(H.scenario({ opts = { search = true }, prepare = not_found, arm = user_map('Q', 'nx'), steps = { 'Q' } }),
    'nmap Q nx')
  t:parity(H.scenario({ opts = { search = true }, prepare = not_found, steps = { '@q' } }), 'macro nx')
end)

H.test('T102', 'counted_macro_stops_at_failing_scroll', function(t)
  t:parity(H.scenario({ prepare = with_macro(200, 'TOP', '<C-D>A!<Esc>'), steps = { '200@q' } }))
end)
