local H = ...
local api = vim.api
local S = require('smoothie')
local prep = H.prep

local AT_90 = { topline = 90, lnum = 100 }

-- Two windows on SHORT; c.orig is the current one (top), at AT_90.
local function split_prepare(c)
  H.fixture('SHORT')
  c.other = api.nvim_get_current_win()
  vim.cmd('split')
  c.orig = api.nvim_get_current_win()
  H.start(AT_90)
end

local function both_views(c)
  c.x.orig = api.nvim_win_is_valid(c.orig) and H.vstr(c.orig) or 'closed'
  c.x.other = H.vstr(c.other)
end

H.test('T56', 'noautocmd_window_switch_keeps_animating', function(t)
  t:parity(H.scenario({
    prepare = split_prepare,
    steps = { '<C-D>', 40, function() vim.cmd('noautocmd wincmd w') end },
    after = both_views,
  }))
end)

H.test('T57', 'typed_window_switch_lands', function(t)
  t:parity(H.scenario({
    prepare = split_prepare,
    steps = { '<C-D>', 40, '<C-w>w', 5, function(c) c.x.orig_after_switch = H.vstr(c.orig) end },
    after = both_views,
  }))
end)

H.test('T58', 'window_closed_no_error', function(t)
  local r = H.scenario({
    native = false,
    prepare = split_prepare,
    steps = { '<C-D>', 40, function(c) api.nvim_win_close(c.orig, true) end },
  }).plugin
  t:settled(r)
  H.sleep(20)
  t:expect(vim.v.errmsg == '', 'v:errmsg=%q', vim.v.errmsg)
  t:expect(not S.is_animating(), 'still animating')
  t:expect(require('smoothie.engine').idle(), 'engine not idle')
end)

-- Only the cursor line is compared: :buffer records its jump before BufLeave fires, so the
-- jumplist holds the displayed line.
H.test('T59', 'bufleave_lands', function(t)
  local r = H.scenario({
    prepare = function(c)
      c.a = H.fixture('SHORT')
      c.b = api.nvim_create_buf(true, true)
      api.nvim_buf_set_lines(c.b, 0, -1, false, H.lines('SHORT', 100))
      H.start(AT_90)
    end,
    steps = {
      '<C-D>', 40, function(c) vim.cmd('buffer ' .. c.b) end,
      60, function(c) vim.cmd('buffer ' .. c.a) end,
    },
  })
  t:settled(r.plugin)
  local p, n = r.plugin.cps[1].lnum, r.native.cps[1].lnum
  t:expect(p == n, 'lnum in A plugin=%d native=%d', p, n)
end)

H.test('T60', 'resize_lands', function(t)
  t:parity(H.scenario({ prepare = prep('SHORT'), steps = { '<C-D>', 40, function() vim.cmd('resize 20') end } }))
end)
