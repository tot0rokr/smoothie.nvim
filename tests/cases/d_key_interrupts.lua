local H = ...
local fn = vim.fn
local S = require('smoothie')
local prep = H.prep

local AT_90 = { topline = 90, lnum = 100 }
local CLICK_ROW, CLICK_COL = 10, 2

H.test('T33', 'typed_keys_see_target', function(t)
  for _, key in ipairs({ 'dd', 'iXYZ<Esc>', 'kkk', '5<C-E>', '/line 900<CR>', ':300<CR>' }) do
    t:parity(H.scenario({ prepare = prep('SHORT', { start = AT_90 }), steps = { '<C-D>', 40, key } }), key)
  end
end)

H.test('T34', 'esc_lands', function(t)
  local r = H.scenario({ prepare = prep('SHORT', { start = AT_90 }), steps = { '<C-D>', 40, '<Esc>' } })
  t:parity(r)
  local t_esc = H.key_time(r.plugin, '<Esc>')
  local after = 0
  for _, s in ipairs(r.plugin.rec) do
    if s.t > t_esc then after = after + 1 end
  end
  t:expect(after <= 1, '%d records after <Esc> (only the landing is allowed)', after)
end)

H.test('T35', 'mouse_click_hits_displayed_text', function(t)
  local r = H.scenario({
    native = false,
    prepare = function()
      prep('SHORT', { start = AT_90 })()
      vim.o.mouse = 'a'
    end,
    arm = function(c)
      H.key_hook = function(k)
        if k == '<LeftMouse>' and not c.w0 then c.w0 = fn.line('w0') end
      end
    end,
    steps = {
      '<C-D>', 40,
      H.mouse('left', 'press', CLICK_ROW, CLICK_COL),
      H.mouse('left', 'release', CLICK_ROW, CLICK_COL),
      5, function(c) c.anim = S.is_animating() end,
    },
  }).plugin
  local w0 = r.c.w0
  t:expect(w0 ~= nil, 'click never reached on_key')
  if not w0 then return end
  t:expect(r.cps[1].lnum == w0 + CLICK_ROW, 'lnum=%d, displayed w0=%d', r.cps[1].lnum, w0)
  t:expect(r.c.anim == false, 'still animating after the click')
  local t_click = H.key_time(r, '<LeftMouse>')
  for _, s in ipairs(r.rec) do
    if s.t > t_click then t:expect(s.top == w0, 'topline changed to %d after the click (w0=%d)', s.top, w0) end
  end
  t:settled(r)
end)

local function continues_through(t, key_step, mousemoveevent)
  local r = H.scenario({
    prepare = function()
      prep('SHORT', { start = AT_90 })()
      vim.o.mousemoveevent = mousemoveevent
    end,
    steps = { '<C-D>', 30, key_step },
  })
  t:parity(r)
  local n = #H.records(r.plugin, 2) - 1
  t:expect(n >= 2, 'records after the event=%d', n)
end

H.test('T36', 'mousemove_does_not_interrupt', function(t)
  continues_through(t, H.mouse('move', '', 5, 5), true)
end)

H.test('T37', 'ignore_key_does_not_interrupt', function(t)
  continues_through(t, '<Ignore>', false)
end)
