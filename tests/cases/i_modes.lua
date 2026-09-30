local H = ...
local api = vim.api
local prep = H.prep

local AT_90 = { topline = 90, lnum = 100 }
local MIN_FLUSHES = 3

H.test('T61', 'timer_startinsert_lands_via_api', function(t)
  local r = H.scenario({
    native = false,
    prepare = prep('SHORT', { start = AT_90 }),
    arm = function(c) c.text = H.buffer_text() end,
    steps = { '<C-D>', 40, function() vim.cmd('startinsert') end },
  }).plugin
  local c = r.cps[1]
  t:settled(r)
  t:expect(c.lnum == 124, 'lnum=%d', c.lnum)
  t:expect(c.mode == 'i', 'mode=%s', c.mode)
  t:expect(c.lines == r.c.text, 'buffer text changed')
end)

H.test('T62', 'cmdline_mid_animation', function(t)
  t:parity(H.scenario({ prepare = prep('SHORT', { start = AT_90 }), steps = { '<C-D>', 40, ':', 20, '<Esc>' } }))
end)

local function count_flushes(c)
  c.flushes = 0
  local orig = api.nvim__redraw
  api.nvim__redraw = function(o)
    if o and o.flush then c.flushes = c.flushes + 1 end
    return orig(o)
  end
  H.on_cleanup(function() api.nvim__redraw = orig end)
end

H.test('T63', 'getchar_loop_flushes', function(t)
  local r = H.scenario({
    prepare = prep('SHORT', { start = AT_90 }),
    arm = function(c)
      count_flushes(c)
      H.map('n', '<F9>', "<Cmd>lua require('smoothie').scroll('<C-D>'); vim.fn.getcharstr()<CR>")
    end,
    native_arm = function()
      H.map('n', '<F9>', [[<Cmd>execute "normal! \<C-D>" | call getcharstr()<CR>]])
    end,
    steps = { '<F9>', 250, 'x' },
  })
  t:parity(r)
  t:expect(r.plugin.c.flushes >= MIN_FLUSHES, 'flush calls inside the getchar loop=%d', r.plugin.c.flushes)
  local control = H.scenario({ native = false, prepare = prep('SHORT', { start = AT_90 }), arm = count_flushes,
    steps = { '<C-D>' } }).plugin
  t:expect(control.c.flushes == 0, 'flush calls for a plain <C-D>=%d', control.c.flushes)
end)

H.test('T64', 'paste_mid_animation_lands_first', function(t)
  local r = H.scenario({
    prepare = prep('SHORT', { start = AT_90 }),
    steps = { '<C-D>', 40, function() api.nvim_paste('PASTED', false, -1) end },
    after = function(c) c.x.line124 = vim.fn.getline(124) end,
  })
  t:parity(r)
  t:expect(r.plugin.x.line124:find('PASTED', 1, true) ~= nil, 'line 124=%q', r.plugin.x.line124)
end)

H.test('T65', 'api_select_mode_noop', function(t)
  local r = H.scenario({
    native = false,
    prepare = prep('SHORT', { start = { topline = 1, lnum = 5 } }),
    arm = function(c)
      c.before = H.capture()
      _G.smoothie_test_ret = nil
      H.map('s', '<F8>', "<Cmd>lua _G.smoothie_test_ret = require('smoothie').scroll('<C-D>')<CR>")
    end,
    steps = { 'gh', 20, '<F8>' },
  }).plugin
  local b, c = r.c.before, r.cps[1]
  t:expect(_G.smoothie_test_ret == false, 'scroll() returned %s', tostring(_G.smoothie_test_ret))
  t:expect(c.mode == 's', 'mode=%s', c.mode)
  t:expect(c.lines == b.lines, 'buffer changed')
  for _, k in ipairs({ 'topline', 'topfill', 'skipcol', 'leftcol', 'lnum', 'col' }) do
    t:expect(c[k] == b[k], '%s %d -> %d', k, b[k], c[k])
  end
  _G.smoothie_test_ret = nil
end)

H.test('T113', 'cmdwin_counted_scroll_stays_in_cmdwin', function(t)
  local HISTORY = 300
  local short = prep('SHORT')
  local r = H.scenario({
    prepare = function(c)
      short(c)
      vim.fn.histdel(':')
      for i = 1, HISTORY do vim.fn.histadd(':', 'echo ' .. i) end
    end,
    steps = {
      'q:', 50, 'gg', H.SETTLE, '3<C-D>', H.SETTLE,
      function(c) c.x.cmdwin = vim.fn.getcmdwintype() end,
      ':quit<CR>', 50,
    },
  })
  vim.fn.histdel(':')
  t:parity(r)
  t:expect(r.plugin.x.cmdwin == ':', 'cmdwin type after 3<C-D>=%q', r.plugin.x.cmdwin)
end)
