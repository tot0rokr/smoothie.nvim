local H = ...
local api, fn = vim.api, vim.fn
local prep = H.prep

local AT_90 = { topline = 90, lnum = 100 }
local REACTOR_ROWS = 12
local REACTOR_SETTLE_MS = 600

local function cursor_moved_at_40(lnum)
  return H.scenario({
    prepare = prep('SHORT', { start = AT_90 }),
    steps = { '<C-D>', 40, function() api.nvim_win_set_cursor(0, { lnum, 0 }) end },
  })
end

H.test('T50', 'external_far_cursor_jump_rebases', function(t)
  local r = cursor_moved_at_40(700)
  t:parity(r)
  t:expect(r.plugin.cps[1].lnum == 700, 'lnum=%d', r.plugin.cps[1].lnum)
end)

H.test('T51', 'external_near_cursor_move_kept', function(t)
  local r = cursor_moved_at_40(112)
  t:parity(r)
  local c = r.plugin.cps[1]
  t:expect(c.lnum == 112 and c.topline == 112, 'lnum=%d top=%d, want 112/112', c.lnum, c.topline)
end)

H.test('T52', 'sticky_header_reactor_terminates', function(t)
  local r = H.scenario({
    prepare = prep('SHORT'),
    arm = function()
      H.au({ 'WinScrolled', 'CursorMoved' }, function()
        if fn.line('.') - fn.line('w0') < REACTOR_ROWS then
          fn.winrestview({ topline = math.max(1, fn.line('.') - REACTOR_ROWS) })
        end
      end)
    end,
    steps = { '<C-D>' },
  })
  t:parity(r)
  local ms = r.plugin.segs[1].quiet - r.plugin.marks[1].t
  t:expect(ms <= REACTOR_SETTLE_MS, 'settled after %.0f ms', ms)
end)

H.test('T53', 'layout_reactor_no_reversal', function(t)
  local ns = api.nvim_create_namespace('smoothie_test_layout')
  local r = H.scenario({
    prepare = prep('SHORT'),
    arm = function()
      H.au('CursorMoved', function()
        local buf, cur = api.nvim_get_current_buf(), fn.line('.')
        api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        for l = fn.line('w0'), fn.line('w$') do
          if l % 6 == 0 and l ~= cur then
            api.nvim_buf_set_extmark(buf, ns, l - 1, 0, { virt_lines = H.VIRT_LINES, virt_lines_above = true })
          end
        end
      end)
    end,
    steps = { '<C-D>' },
  })
  t:parity(r)
  t:expect(H.reversals(r.plugin, 'top') == 0, 'topline reversals=%d', H.reversals(r.plugin, 'top'))
end)

H.test('T54', 'async_edit_above_tracks_text', function(t)
  local r = H.scenario({
    prepare = prep('SHORT', { start = AT_90 }),
    steps = { '<C-D>', 40, function() api.nvim_buf_set_lines(0, 0, 50, false, {}) end },
    after = function(c) c.x.text = api.nvim_get_current_line() end,
  })
  t:parity(r)
  t:expect(r.plugin.x.text == 'line 124', 'cursor line=%q', r.plugin.x.text)
end)

H.test('T55', 'timer_stopall_harmless', function(t)
  local r = H.scenario({
    prepare = prep('SHORT', { start = AT_90 }),
    steps = { '<C-D>', 30, function() fn.timer_stopall() end, H.SETTLE, '<C-D>' },
  })
  t:parity(r)
  t:expect(H.frames(r.plugin, 2) >= 3, 'following <C-D> frames=%d', H.frames(r.plugin, 2))
end)

H.test('T104', 'async_edit_near_target_top_follows_native', function(t)
  for _, case in ipairs({
    { 'delete between top and cursor', function() api.nvim_buf_set_lines(0, 115, 119, false, {}) end },
    { 'insert between top and cursor', function() api.nvim_buf_set_lines(0, 116, 116, false, { 'a', 'b', 'c' }) end },
    { 'delete the top line', function() api.nvim_buf_set_lines(0, 112, 117, false, {}) end },
    { 'replace the top line', function() api.nvim_buf_set_lines(0, 113, 114, false, { 'x' }) end },
  }) do
    t:parity(H.scenario({ prepare = prep('SHORT', { start = AT_90 }), steps = { '<C-D>', 40, case[2] } }), case[1])
  end
end)

H.test('T105', 'scrolloff_reactor_keeps_native_view', function(t)
  local SO_EVEN, SO_ODD = 8, 3
  t:parity(H.scenario({
    prepare = prep('IND'),
    arm = function()
      H.au('CursorMoved', function() vim.wo.scrolloff = fn.line('.') % 2 == 0 and SO_EVEN or SO_ODD end)
    end,
    steps = { '<C-F>' },
  }))
end)
