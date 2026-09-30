local H = ...
local api, fn = vim.api, vim.fn
local S = require('smoothie')

local DEFAULT_KEYS = { '<C-D>', '<C-U>', '<C-F>', '<C-B>', '<PageDown>', '<PageUp>', '<S-Down>', '<S-Up>',
  'z+', 'z^', 'zt', 'z<CR>', 'z.', 'zz', 'z-', 'zb' }
local PLUGS = { 'SmoothieDownwards', 'SmoothieUpwards', 'SmoothieForwards', 'SmoothieBackwards', 'Smoothie_gg',
  'Smoothie_G' }
local FOREIGN_MODES = { 's', 'o', 'i', 'c', 't' }

local function ours(lhs, mode)
  local m = fn.maparg(lhs, mode, false, true)
  return m.desc == 'smoothie ' .. lhs
end

local function expect_not_ours(t, lhs, modes)
  for _, m in ipairs(modes) do
    local d = fn.maparg(lhs, m, false, true).desc
    t:expect(not (d and d:find('^smoothie')), '%s mapped by the plugin in mode %s', lhs, m)
  end
end

H.test('T01', 'maps_default_n_x_only', function(t)
  H.setup({})
  for _, lhs in ipairs(DEFAULT_KEYS) do
    for _, m in ipairs({ 'n', 'x' }) do
      t:expect(ours(lhs, m), '%s not mapped in %s with desc "smoothie %s"', lhs, m, lhs)
    end
    expect_not_ours(t, lhs, FOREIGN_MODES)
  end
  local got = vim.deepcopy(S.default_keys)
  table.sort(got)
  local want = vim.deepcopy(DEFAULT_KEYS)
  table.sort(want)
  t:expect(vim.deep_equal(got, want), 'default_keys=%s', vim.inspect(S.default_keys))
end)

H.test('T02', 'opt_in_groups', function(t)
  H.setup({ jumps = true, search = true, mouse = true })
  for _, lhs in ipairs({ 'gg', 'G', 'n', 'N', 'g*', 'g#', '<ScrollWheelDown>', '<ScrollWheelUp>' }) do
    for _, m in ipairs({ 'n', 'x' }) do
      t:expect(ours(lhs, m), '%s not mapped in %s', lhs, m)
    end
  end
  for _, lhs in ipairs({ '*', '#' }) do
    t:expect(ours(lhs, 'n'), '%s not mapped in n', lhs)
    t:expect(fn.maparg(lhs, 'x') ~= '' and not ours(lhs, 'x'), '%s in x is not the Neovim default (desc=%s)', lhs,
      tostring(fn.maparg(lhs, 'x', false, true).desc))
  end
  t:expect(#S.skipped == 0, 'Neovim defaults reported as skipped: %s', vim.inspect(S.skipped))
end)

H.test('T03', 'existing_user_mapping_not_overridden', function(t)
  H.map('n', '<C-D>', '<Cmd>let g:u=1<CR>')
  H.setup({})
  vim.g.u = nil
  H.fixture('SHORT')
  H.start('MID')
  api.nvim_input('<C-D>')
  H.sleep(30)
  t:expect(vim.g.u == 1, 'user mapping did not run (g:u=%s)', tostring(vim.g.u))
  t:expect(vim.tbl_contains(S.skipped, 'n <C-D>'), 'skipped=%s', vim.inspect(S.skipped))
  t:expect(ours('<C-D>', 'x'), '<C-D> not mapped in x')
  local health = H.checkhealth('smoothie')
  t:expect(health:find('<C-D>', 1, true) ~= nil, 'checkhealth does not mention <C-D>: %s', health)
  vim.g.u = nil
end)

H.test('T115', 'default_timing', function(t)
  H.setup({})
  local c = S.config
  t:expect(c.duration == 400 and c.easing == 'cubic' and c.fps == 60, 'duration=%s easing=%s fps=%s',
    tostring(c.duration), tostring(c.easing), tostring(c.fps))
end)

H.test('T123', 'quiet_default_off', function(t)
  H.setup({})
  t:expect(S.config.quiet == false, 'setup{}: quiet=%s', tostring(S.config.quiet))
  if fn.exists('+eventignorewin') == 1 then
    H.setup({ quiet = true })
    t:expect(S.config.quiet == true, 'setup{quiet=true}: quiet=%s', tostring(S.config.quiet))
    H.setup({})
    t:expect(S.config.quiet == false, 'setup{} after setup{quiet=true}: quiet=%s', tostring(S.config.quiet))
  end
  local ok = pcall(S.setup, { quiet = 1 })
  t:expect(not ok, 'setup{quiet=1} did not raise')
end)

H.test('T114', 'buffer_local_mapping_does_not_block_global', function(t)
  local LOCAL = { { 'n', '<C-D>' }, { 'x', 'z<CR>' } }
  local buf = api.nvim_get_current_buf()
  local function global(mode, lhs)
    for _, m in ipairs(api.nvim_get_keymap(mode)) do
      if m.lhs == lhs then return m end
    end
  end
  for _, c in ipairs(LOCAL) do vim.keymap.set(c[1], c[2], '<Nop>', { buffer = buf }) end
  H.setup({})
  t:expect(#S.skipped == 0, 'skipped=%s', vim.inspect(S.skipped))
  for _, c in ipairs(LOCAL) do
    local g = global(c[1], c[2])
    t:expect(g ~= nil and g.desc == 'smoothie ' .. c[2], '%s %s: no global smoothie mapping', c[1], c[2])
  end
  H.setup({ keys = {} })
  for _, c in ipairs(LOCAL) do
    t:expect(global(c[1], c[2]) == nil, '%s %s: stale global smoothie mapping', c[1], c[2])
    vim.keymap.del(c[1], c[2], { buffer = buf })
  end
end)

H.test('T04', 'setup_twice_replaces_own_maps', function(t)
  H.setup({})
  H.setup({ keys = { 'zz' } })
  for _, m in ipairs({ 'n', 'x' }) do
    t:expect(fn.maparg('<C-D>', m) == '', '<C-D> still mapped in %s', m)
    t:expect(ours('zz', m), 'zz not mapped in %s', m)
  end
end)

H.test('T05', 'setup_unknown_option_errors', function(t)
  for _, opts in ipairs({ { duraton = 1 }, { quite = true } }) do
    local ok, err = pcall(S.setup, opts)
    t:expect(not ok and tostring(err):find('unknown option', 1, true) ~= nil, 'setup(%s): ok=%s err=%s',
      vim.inspect(opts), tostring(ok), tostring(err))
  end
end)

H.test('T06', 'setup_bad_type_errors', function(t)
  local ok = pcall(S.setup, { duration = 'x' })
  t:expect(not ok, 'setup{duration="x"} did not raise')
end)

H.test('T07', 'plug_mappings_n_x', function(t)
  for _, name in ipairs(PLUGS) do
    local lhs = '<Plug>(' .. name .. ')'
    for _, m in ipairs({ 'n', 'x' }) do t:expect(fn.maparg(lhs, m) ~= '', '%s missing in %s', lhs, m) end
    for _, m in ipairs({ 'o', 's' }) do t:expect(fn.maparg(lhs, m) == '', '%s defined in %s', lhs, m) end
  end
end)

local LIST_MAPS = [[
local out = {}
for _, m in ipairs({ 'n', 'x' }) do
  for _, k in ipairs(vim.api.nvim_get_keymap(m)) do
    if k.desc and k.desc:find('^smoothie ') and not k.lhs:find('^<Plug>') then out[#out + 1] = m .. ' ' .. k.lhs end
  end
end
table.sort(out)
io.stdout:write(table.concat(out, ','))
]]

H.test('T08', 'legacy_globals', function(t)
  local script = fn.tempname() .. '.lua'
  local f = assert(io.open(script, 'w'))
  f:write(LIST_MAPS)
  f:close()
  local function child(let)
    local r = H.system({ vim.v.progpath, '--headless', '--clean', '--cmd', let, '--cmd',
      'set rtp^=' .. fn.fnameescape(H.ROOT), '-c', 'luafile ' .. fn.fnameescape(script), '-c', 'qa!' })
    t:expect(r.code == 0 and r.stderr == '', '%s: exit %d, stderr=%s', let, r.code, r.stderr)
    local set = {}
    for _, s in ipairs(vim.split(r.stdout, ',', { trimempty = true })) do set[s] = true end
    return set, r
  end
  local a, ra = child('let g:smoothie_no_default_mappings = 1')
  t:expect(next(a) == nil, '(a) mappings present: %s stderr=%s', ra.stdout, ra.stderr)
  local b, rb = child('let g:smoothie_experimental_mappings = 1')
  for _, k in ipairs({ 'n gg', 'x gg', 'n G', 'x G', 'n <C-D>' }) do
    t:expect(b[k], '(b) %s missing: %s stderr=%s', k, rb.stdout, rb.stderr)
  end
  local c, rc = child("let g:smoothie_remapped_commands = ['zz']")
  t:expect(vim.deep_equal(c, { ['n zz'] = true, ['x zz'] = true }), '(c) got %s stderr=%s', rc.stdout, rc.stderr)
  os.remove(script)
end)

local DISABLE = {
  { 'g:smoothie_enabled=0', prepare = function() vim.g.smoothie_enabled = 0 end },
  { 'w:smoothie_enabled=0', prepare = function() vim.w.smoothie_enabled = 0 end },
  { 'b:smoothie_enabled=0', prepare = function() vim.b.smoothie_enabled = 0 end },
  { 'setup{enabled=false}', opts = { enabled = false } },
  { ':Smoothie disable', prepare = function() vim.cmd('Smoothie disable') end },
  { 'g:neovide', prepare = function() vim.g.neovide = true end },
  { 'exclude_filetypes', opts = { exclude_filetypes = { 'foo' } }, prepare = function() vim.bo.filetype = 'foo' end },
}

H.test('T09', 'disable_switches_run_native', function(t)
  for _, case in ipairs(DISABLE) do
    local r = H.scenario({
      opts = case.opts or {},
      prepare = function()
        H.fixture('SHORT')
        H.start('MID')
        if case.prepare then case.prepare() end
      end,
      steps = { '<C-D>', 5, function(c) c.anim5 = S.is_animating() end },
    })
    t:parity(r, case[1])
    t:expect(H.frames(r.plugin) <= 1, '%s: frames=%d', case[1], H.frames(r.plugin))
    t:expect(r.plugin.c.anim5 == false, '%s: animating 5 ms after the input', case[1])
  end
end)

local SHORT_BYTES_OVER = 50000
local SHORT_BYTES_UNDER = 1000000
local FILE_LINES = 2000

local function write_file(with_nul)
  local path = fn.tempname()
  local f = assert(io.open(path, 'wb'))
  for i = 1, FILE_LINES do
    f:write(('line %d%s\n'):format(i, with_nul and '\0' or ''))
  end
  f:close()
  return path
end

local function scroll_case(opts, prepare)
  return H.scenario({
    opts = opts,
    prepare = function(c)
      prepare(c)
      H.start('MID')
    end,
    steps = { '<C-D>', 5, function(c)
      c.anim5 = S.is_animating()
      c.bin = vim.b.smoothie_binary
    end },
  })
end

local function expect_instant(t, r, label)
  t:parity(r, label)
  t:expect(H.frames(r.plugin) <= 1, '%s: frames=%d', label, H.frames(r.plugin))
  t:expect(r.plugin.c.anim5 == false, '%s: animating 5 ms after the input', label)
end

local function expect_animated(t, r, label)
  t:parity(r, label)
  t:expect(H.frames(r.plugin) >= 3, '%s: frames=%d', label, H.frames(r.plugin))
end

H.test('T137', 'max_filesize_scrolls_instantly', function(t)
  local short = function() H.fixture('SHORT') end
  expect_instant(t, scroll_case({ max_filesize = SHORT_BYTES_OVER }, short), 'buffer over max_filesize')
  expect_animated(t, scroll_case({ max_filesize = SHORT_BYTES_UNDER }, short), 'buffer under max_filesize')
end)

H.test('T138', 'binary_buffer_scrolls_instantly', function(t)
  local binary_file, text_file = write_file(true), write_file(false)
  local function open(path) return function() vim.cmd('noswapfile edit ' .. fn.fnameescape(path)) end end
  expect_instant(t, scroll_case({}, function()
    H.fixture('SHORT')
    vim.bo.binary = true
  end), "'binary' buffer")
  local r = scroll_case({}, open(binary_file))
  expect_instant(t, r, 'file with a NUL byte')
  t:expect(r.plugin.c.bin == true, 'b:smoothie_binary=%s after a NUL file', tostring(r.plugin.c.bin))
  expect_animated(t, scroll_case({ exclude_binary = false }, open(binary_file)), 'exclude_binary=false')
  expect_animated(t, scroll_case({}, function()
    open(binary_file)()
    vim.b.smoothie_binary = false
  end), 'b:smoothie_binary=false override')
  r = scroll_case({}, open(text_file))
  expect_animated(t, r, 'text file')
  t:expect(r.plugin.c.bin == false, 'b:smoothie_binary=%s after a text file', tostring(r.plugin.c.bin))
  os.remove(binary_file)
  os.remove(text_file)
end)

H.test('T139', 'file_limit_options_validate', function(t)
  H.setup({})
  t:expect(S.config.max_filesize == false and S.config.exclude_binary == true, 'defaults max_filesize=%s exclude_binary=%s',
    tostring(S.config.max_filesize), tostring(S.config.exclude_binary))
  for _, bad in ipairs({ { max_filesize = 'x' }, { max_filesize = 0 }, { max_filesize = true }, { exclude_binary = 1 } }) do
    t:expect(not pcall(S.setup, bad), 'setup%s did not raise', vim.inspect(bad))
  end
end)

H.test('T10', 'smoothie_command', function(t)
  H.setup({})
  local function enabled() return S.enabled(api.nvim_get_current_win()) end
  local seq = {}
  for _, cmd in ipairs({ 'Smoothie toggle', 'Smoothie toggle', 'Smoothie disable', 'Smoothie enable', 'Smoothie',
    'Smoothie' }) do
    vim.cmd(cmd)
    seq[#seq + 1] = enabled()
  end
  t:expect(vim.deep_equal(seq, { false, true, false, true, false, true }), 'enabled sequence %s', vim.inspect(seq))
  local ok, err = pcall(vim.cmd, 'Smoothie bogus')
  t:expect(not ok and tostring(err):find('unknown argument', 1, true) ~= nil, ':Smoothie bogus: ok=%s err=%s',
    tostring(ok), tostring(err))
  local comp = fn.getcompletion('Smoothie ', 'cmdline')
  for _, a in ipairs({ 'enable', 'disable', 'toggle' }) do
    t:expect(vim.tbl_contains(comp, a), 'completion %s lacks %s', vim.inspect(comp), a)
  end
end)
