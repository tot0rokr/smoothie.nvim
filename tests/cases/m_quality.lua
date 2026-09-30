local H = ...
local fn = vim.fn
local prep = H.prep

local SLACK_FRAMES = 3
local SLACK_MS = 30
local FIRST_FRAME_MS = 10
local STARTUP_BUDGET_MS = tonumber(vim.env.SMOOTHIE_TEST_STARTUP_BUDGET_MS) or 1.5
local STARTUP_RUNS = 7
local DEFAULT_KEYS = { '<C-D>', '<C-U>', '<C-F>', '<C-B>', '<PageDown>', '<PageUp>', '<S-Down>', '<S-Up>',
  'z+', 'z^', 'zt', 'z<CR>', 'z.', 'zz', 'z-', 'zb' }

H.test('T88', 'frames_monotonic_no_reversal', function(t)
  for _, f in ipairs({ 'SHORT', 'WRAP', 'WRAPSS', 'FOLDS', 'VLINES' }) do
    for _, so in ipairs({ 0, 5 }) do
      for _, key in ipairs({ '<C-D>', '<C-U>', '<C-F>', '<C-B>', 'zt', 'zb' }) do
        local label = string.format('%s so=%d %s', f, so, key)
        local r = H.scenario({ prepare = prep(f, { so = so }), steps = { key } })
        if t:parity(r, label) then
          local rt, rl = H.reversals(r.plugin, 'top'), H.reversals(r.plugin, 'lnum')
          t:expect(rt == 0 and rl == 0, '%s: reversals top=%d lnum=%d', label, rt, rl)
        end
      end
    end
  end
end)

H.test('T89', 'first_frame_at_keypress', function(t)
  local r = H.scenario({ native = false, prepare = prep('SHORT'), steps = { '<C-D>' } }).plugin
  local ms = H.first_change_ms(r)
  t:expect(ms and ms <= FIRST_FRAME_MS, 'first changed record after %s ms', tostring(ms))
end)

H.test('T90', 'duration_bound', function(t)
  for _, key in ipairs(DEFAULT_KEYS) do
    local r = H.scenario({ native = false, prepare = prep('SHORT'), steps = { key } }).plugin
    t.cases = t.cases + 1
    t:settled(r, key)
    local c = require('smoothie').config
    local bound = c.duration + SLACK_FRAMES * 1000 / c.fps + SLACK_MS
    local ms = r.last_anim and (r.last_anim - r.marks[1].t) or 0
    t:expect(ms <= bound, '%s: animating for %.0f ms > %.0f ms', key, ms, bound)
  end
end)

H.test('T91', 'folds_animate_and_j_works', function(t)
  local r = H.scenario({ prepare = prep('FOLDS'), steps = { '<C-D>', H.SETTLE, 'j' } })
  t:parity(r)
  t:expect(H.frames(r.plugin, 1) >= 4, 'frames=%d', H.frames(r.plugin, 1))
  t:expect(r.plugin.cps[2].lnum ~= r.plugin.cps[1].lnum, 'j did not move the cursor (lnum %d)', r.plugin.cps[2].lnum)
end)

H.test('T92', 'cursor_never_inside_closed_fold', function(t)
  local r = H.scenario({ native = false, prepare = prep('FOLDS'), steps = { '<C-D>', H.SETTLE, '<C-F>' } }).plugin
  t:settled(r)
  for _, s in ipairs(r.rec) do
    t:expect(s.fc == -1 or s.fc == s.lnum, 'cursor on %d inside the fold starting at %d', s.lnum, s.fc)
  end
end)

H.test('T93', 'wrapss_frames_row_exact', function(t)
  local r = H.scenario({ prepare = prep('WRAPSS'), steps = { '<C-D>' } })
  t:parity(r)
  local rec, partial = H.records(r.plugin), false
  for k = 2, #rec - 1 do partial = partial or rec[k].skip > 0 end
  t:expect(partial, 'no intermediate record with skipcol > 0')
end)

H.test('T94', 'wrap_nosms_frames_line_aligned', function(t)
  local r = H.scenario({ prepare = prep('WRAP'), steps = { '<C-D>' } })
  t:parity(r)
  for _, s in ipairs(r.plugin.rec) do t:expect(s.skip == 0, 'skipcol=%d in a record', s.skip) end
end)

H.test('T95', 'frame_error_lands_and_raises', function(t)
  local r = H.scenario({
    prepare = prep('SHORT'),
    arm = function()
      local calls = 0
      require('smoothie.engine')._fault = function()
        calls = calls + 1
        if calls == 2 then error('injected frame fault') end
      end
    end,
    native_arm = false,
    steps = { '<C-D>', H.SETTLE, function(c) c.messages = fn.execute('messages') end, '<C-D>' },
  })
  t:parity(r)
  local p = r.plugin
  t:expect(p.c.messages:find('smoothie:', 1, true) ~= nil, ':messages lacks "smoothie:": %s', p.c.messages)
  t:expect(H.frames(p, 2) >= 3, 'next <C-D> frames=%d', H.frames(p, 2))
end)

H.test('T96', 'idle_footprint', function(t)
  local r = H.scenario({ native = false, prepare = prep('SHORT'), steps = { '<C-D>' } }).plugin
  t:settled(r)
  H.sleep(10)
  t:expect(require('smoothie.engine').idle(), 'engine not idle')
end)

-- Measured on a copy in the temp dir: on a network-mounted home every file open is a server
-- round trip (about 0.3 ms here, and startup opens three files), which is not the plugin's cost.
H.test('T97', 'startup_lazy_engine', function(t)
  local root = fn.tempname()
  fn.mkdir(root, 'p')
  H.on_cleanup(function() fn.delete(root, 'rf') end)
  local cp = H.system({ 'cp', '-R', H.ROOT .. '/plugin', H.ROOT .. '/lua', H.ROOT .. '/autoload', root })
  assert(cp.code == 0, 'copying the plugin failed: ' .. cp.stderr)
  local best
  for _ = 1, STARTUP_RUNS do
    local log = fn.tempname()
    local r = H.system({ vim.v.progpath, '--headless', '--clean', '--cmd', 'set rtp^=' .. fn.fnameescape(root),
      '--startuptime', log, '-c', 'lua io.stdout:write(tostring(package.loaded["smoothie.engine"] ~= nil))', '-c', 'qa' })
    t:expect(r.stdout == 'false', 'engine loaded at startup: stdout=%q stderr=%q', r.stdout, r.stderr)
    local ms
    for line in io.lines(log) do
      local total, path = line:match('^%S+%s+(%S+)%s+%S+: sourcing (.*)$')
      if path and path:find('/plugin/smoothie.lua', 1, true) then ms = tonumber(total) end
    end
    os.remove(log)
    t:expect(ms ~= nil, 'plugin/smoothie.lua not sourced')
    if ms then best = math.min(best or ms, ms) end
  end
  if best then t:expect(best <= STARTUP_BUDGET_MS, 'plugin/smoothie.lua took %.3f ms', best) end
end)

H.test('T98', 'health_runs', function(t)
  H.map('n', '<C-U>', '<Cmd>let g:smoothie_test_u = 1<CR>')
  H.setup({})
  local ok, text = pcall(H.checkhealth, 'smoothie')
  t:expect(ok, 'checkhealth raised: %s', tostring(text))
  if not ok then return end
  t:expect(not text:find('Failed to run healthcheck', 1, true), 'health check failed: %s', text)
  t:expect(text:find('<C-U>', 1, true) ~= nil, 'skipped <C-U> not listed: %s', text)
  for _, g in ipairs({ 'neovide', 'started_by_firenvim' }) do
    vim.g[g] = 0
    text = H.checkhealth('smoothie')
    vim.g[g] = nil
    t:expect(not text:find('disabled', 1, true), 'g:%s = 0 reported as disabled: %s', g, text)
  end
  H.setup({ quiet = true })
  text = H.checkhealth('smoothie')
  t:expect(not text:find('Failed to run healthcheck', 1, true), 'quiet: health check failed: %s', text)
  t:expect(text:find('<C-U>', 1, true) ~= nil, 'quiet: skipped <C-U> not listed: %s', text)
  t:expect(text:find('quiet = true', 1, true) ~= nil, 'setup{quiet=true}: setting not reported: %s', text)
  local state = fn.exists('+eventignorewin') == 1 and "'eventignorewin': available" or 'quiet = true acts as false'
  t:expect(text:find(state, 1, true) ~= nil, 'setup{quiet=true}: "%s" not reported: %s', state, text)
end)
