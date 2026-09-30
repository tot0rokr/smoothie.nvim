local H = ...

local FAST = { duration = 80 }
local KEYS = { '<C-D>', '<C-U>', '<C-F>', '<C-B>', '<PageDown>', '<S-Up>', 'zz', 'zt', 'zb', 'z<CR>', 'z.', 'z-', 'z+',
  'z^', '3<C-D>', '2<C-F>', '50zt' }
local MATRIX_FIXTURES = { { 'SHORT' }, { 'IND', sol = true }, { 'WRAP' }, { 'WRAPSS' }, { 'FOLDS' }, { 'VLINES' } }
local FIRST_CHANGE_MS = 10
local prep = H.prep

H.test('T11', 'parity_single_matrix', function(t)
  local sos = H.FULL and { 0, 5, 999 } or { 0, 5 }
  local starts = H.FULL and { 'MID', 'END', 'TOP' } or { 'MID', 'END' }
  for _, f in ipairs(MATRIX_FIXTURES) do
    for _, so in ipairs(sos) do
      for _, start in ipairs(starts) do
        for _, key in ipairs(KEYS) do
          local r = H.scenario({ opts = FAST, prepare = prep(f[1], { so = so, sol = f.sol, start = start }), steps = { key } })
          t:parity(r, string.format('%s so=%d %s %s', f[1], so, start, key))
        end
      end
    end
  end
end)

H.test('T12', 'parity_wrap_5x_ctrl_d_10ms', function(t)
  t:parity(H.scenario({ opts = FAST, prepare = prep('WRAP', { start = 'TOP' }), steps = H.rep('<C-D>', 5, 10) }))
end)

H.test('T13', 'parity_ctrl_f_eof_so5', function(t)
  for _, f in ipairs({ { 'SHORT', 2000 }, { 'WRAP', 3000 }, { 'WRAPSS', 3000 } }) do
    local r = H.scenario({ opts = FAST, prepare = prep(f[1], { n = f[2], so = 5, start = 'NEAR_EOF' }), steps = { '<C-F>' } })
    t:parity(r, f[1])
    if f[1] == 'SHORT' then
      for _, run in ipairs({ 'plugin', 'native' }) do
        local c = r[run].cps[1]
        t:expect(c.topline == 2000 and c.lnum == 2000, '%s run: top=%d lnum=%d, want 2000/2000', run, c.topline, c.lnum)
      end
    end
  end
end)

H.test('T14', 'parity_eof_so5_then_key', function(t)
  for _, key in ipairs({ 'j', '<C-E>', '<C-Y>', 'k' }) do
    t:parity(H.scenario({ opts = FAST, prepare = prep('SHORT', { n = 2000, so = 5, start = 'NEAR_EOF' }),
      steps = { '<C-F>', 40, key } }), key)
  end
end)

H.test('T15', 'count_sets_scroll_once', function(t)
  local r = H.scenario({ opts = FAST, prepare = prep('SHORT'), steps = { '3<C-D>', H.SETTLE, '<C-D>' } })
  t:parity(r)
  t:expect(r.plugin.cps[2].scroll == 3, "&l:scroll=%d", r.plugin.cps[2].scroll)
end)

H.test('T16', 'curswant_dollar_survives', function(t)
  local r = H.scenario({ opts = FAST, prepare = prep('IND'), steps = { '$', 10, '<C-D>' } })
  t:parity(r)
  t:expect(r.plugin.cps[1].curswant == vim.v.maxcol, 'curswant=%d', r.plugin.cps[1].curswant)
end)

H.test('T17', 'startofline_column', function(t)
  t:parity(H.scenario({
    opts = FAST,
    prepare = prep('IND', { sol = true, start = { topline = 1000, lnum = 1010, col = 5, curswant = 5 } }),
    steps = { '<C-D>', H.SETTLE, '<C-U>' },
  }))
end)

H.test('T18', 'jumplist_gg_G', function(t)
  t:parity(H.scenario({
    opts = { jumps = true },
    prepare = prep('SHORT', { start = { topline = 490, lnum = 500 } }),
    steps = { '700G', H.SETTLE, 'gg' },
  }))
end)

H.test('T19', 'zcr_column_only_not_animated', function(t)
  local r = H.scenario({ opts = FAST, prepare = prep('IND', { start = { topline = 1010, lnum = 1010, col = 0 } }),
    steps = { 'z<CR>' } })
  t:parity(r)
  t:expect(H.frames(r.plugin) <= 1, 'frames=%d', H.frames(r.plugin))
end)

H.test('T20', 'ctrl_d_last_line_noop', function(t)
  local r = H.scenario({ opts = FAST, prepare = prep('SHORT', { start = 'END' }), steps = { '<C-D>' } })
  t:parity(r)
  t:expect(H.frames(r.plugin) == 0, 'frames=%d', H.frames(r.plugin))
end)

H.test('T21', 'ctrl_d_near_eof_animates_cursor_only', function(t)
  local n = 10000
  local r = H.scenario({ opts = FAST, prepare = prep('SHORT', { start = { topline = n - H.HEIGHT + 1, lnum = n - 40 } }),
    steps = { '<C-D>' } })
  t:parity(r)
  local rec, lnums, count = H.records(r.plugin), {}, 0
  for _, s in ipairs(rec) do
    if not lnums[s.lnum] then
      lnums[s.lnum] = true
      count = count + 1
    end
    t:expect(s.top == rec[1].top, 'topline moved to %d', s.top)
  end
  t:expect(count >= 3, 'distinct lnum records=%d', count)
end)

H.test('T22', 'diff_filler_parity', function(t)
  t:parity(H.scenario({
    opts = FAST,
    prepare = function(c)
      c.left, c.right = H.diff_fixture()
      H.start({ topline = 290, lnum = 300 })
    end,
    steps = { '<C-D>', H.SETTLE, '<C-U>' },
    after = function(c) c.x.right = H.vstr(c.right) end,
  }))
end)

H.test('T23', 'far_jump_bounded', function(t)
  local r = H.scenario({ opts = { jumps = true }, prepare = prep('BIG', { start = 'TOP' }), steps = { 'G', H.SETTLE, 'gg' } })
  t:parity(r)
  local c = require('smoothie').config
  local frame_bound = math.ceil(c.duration * c.fps / 1000) + 2
  for seg, key in ipairs({ 'G', 'gg' }) do
    local frames, first = H.frames(r.plugin, seg), H.first_change_ms(r.plugin, seg)
    t:expect(frames <= frame_bound, '%s: frames=%d > %d', key, frames, frame_bound)
    t:expect(first and first <= FIRST_CHANGE_MS, '%s: first view change after %s ms', key, tostring(first))
  end
end)

H.test('T109', 'wrap_far_jump_animates_max_travel', function(t)
  local LINES, LEN = 2000, 1000
  local cap_rows = 2 * H.HEIGHT
  for _, case in ipairs({ { 'G', 'TOP' }, { 'gg', 'END' } }) do
    local key = case[1]
    local r = H.scenario({
      opts = { jumps = true },
      prepare = function()
        local lines = {}
        for i = 1, LINES do lines[i] = ('x'):rep(LEN) .. ' ' .. i end
        vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.wo.wrap = true
        H.start(case[2])
      end,
      steps = { key },
    })
    t:parity(r, key)
    local rec = H.records(r.plugin)
    local a, b = math.min(rec[2].top, rec[#rec].top), math.max(rec[2].top, rec[#rec].top)
    local rows = a == b and 0 or vim.api.nvim_win_text_height(0, { start_row = a - 1, end_row = b - 2 }).all
    t:expect(rows <= cap_rows, '%s: %d rows animated after the first frame (max_travel %d rows)', key, rows, cap_rows)
  end
end)
