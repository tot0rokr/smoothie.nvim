local H = ...
local api, fn = vim.api, vim.fn
local prep = H.prep

local SEARCH = { search = true }
local WHEEL, NO_WHEEL = { mouse = true }, { mouse = false }
local WHEEL_ROW, OTHER_WIN_COL = 10, 90

local function runs_native(t, prepare)
  local r = H.scenario({ prepare = prepare, steps = { '<C-D>' } })
  t:parity(r)
  t:expect(H.frames(r.plugin) <= 1, 'frames=%d', H.frames(r.plugin))
end

H.test('T71', 'foldopen_all_runs_native', function(t)
  runs_native(t, function()
    prep('FOLDS')()
    vim.o.foldopen = 'all'
  end)
end)

H.test('T72', 'foldclose_all_runs_native', function(t)
  runs_native(t, function()
    prep('FOLDS')()
    vim.o.foldclose = 'all'
  end)
end)

H.test('T73', 'scrollbind_runs_native', function(t)
  for _, opt in ipairs({ 'scrollbind', 'cursorbind' }) do
    local r = H.scenario({
      prepare = function(c)
        H.fixture('SHORT')
        vim.cmd('vsplit')
        c.wins = api.nvim_list_wins()
        for _, w in ipairs(c.wins) do
          vim.wo[w][opt] = true
          api.nvim_win_call(w, function() H.start('MID') end)
        end
      end,
      steps = { '<C-D>' },
      after = function(c)
        for i, w in ipairs(c.wins) do c.x['win' .. i] = H.vstr(w) end
      end,
    })
    t:parity(r, opt)
    t:expect(H.frames(r.plugin) <= 1, '%s: frames=%d', opt, H.frames(r.plugin))
  end
end)

H.test('T74', 'nowrap_horizontal_guard', function(t)
  local r = H.scenario({
    prepare = prep('LONGSHORT', { start = { topline = 990, lnum = 1000, col = 150, curswant = 150 } }),
    arm = function(c) c.leftcol = fn.winsaveview().leftcol end,
    steps = { '<C-D>' },
  })
  t:expect(r.plugin.c.leftcol > 0, '(a) precondition: leftcol=%d', r.plugin.c.leftcol)
  t:parity(r, '(a)')
  t:expect(H.frames(r.plugin) <= 1, '(a) frames=%d', H.frames(r.plugin))
  r = H.scenario({ prepare = prep('LONGSHORT', { start = { topline = 1000, lnum = 1010, col = 0 } }), steps = { '<C-D>' } })
  t:parity(r, '(b)')
  t:expect(H.frames(r.plugin) >= 3, '(b) frames=%d', H.frames(r.plugin))
  for _, s in ipairs(r.plugin.rec) do t:expect(s.left == 0, '(b) leftcol=%d in a record', s.left) end
end)

H.test('T75', 'search_foldopen_parity', function(t)
  for _, foldopen in ipairs({ 'default', '' }) do
    local r = H.scenario({
      opts = SEARCH,
      prepare = function()
        H.fixture('SHORT')
        vim.cmd('setlocal foldenable foldmethod=manual')
        vim.cmd('500,520fold')
        fn.setreg('/', 'line 510$')
        if foldopen == '' then vim.o.foldopen = '' end
        H.start('TOP')
      end,
      steps = { 'n' },
      after = function(c) c.x.foldclosed510 = fn.foldclosed(510) end,
    })
    t:parity(r, 'foldopen=' .. foldopen)
    local want = foldopen == '' and 500 or -1
    t:expect(r.plugin.x.foldclosed510 == want, 'foldopen=%s: foldclosed(510)=%d, want %d', foldopen,
      r.plugin.x.foldclosed510, want)
  end
end)

H.test('T76', 'search_n_hlsearch_jumplist', function(t)
  local r = H.scenario({
    opts = SEARCH,
    prepare = prep('SHORT', { start = 'TOP' }),
    steps = { '/line 700<CR>', H.SETTLE, ':noh<CR>', H.SETTLE, 'gg', H.SETTLE, 'n' },
  })
  t:parity(r)
  t:expect(r.plugin.cps[4].hlsearch == 1, 'v:hlsearch=%d', r.plugin.cps[4].hlsearch)
end)

H.test('T77', 'search_not_found', function(t)
  local r = H.scenario({
    native = false,
    opts = SEARCH,
    prepare = function()
      prep('SHORT', { start = 'TOP' })()
      fn.setreg('/', 'zzzz')
    end,
    arm = function(c)
      vim.v.errmsg = ''
      c.before = H.vstr(0)
    end,
    steps = { 'n' },
  }).plugin
  t:settled(r)
  t:expect(vim.v.errmsg:find('E486', 1, true) ~= nil, 'v:errmsg=%q', vim.v.errmsg)
  t:expect(fn.execute('messages'):find('E486', 1, true) ~= nil, ':messages lacks E486')
  t:expect(H.vstr(0) == r.c.before, 'view changed: %s -> %s', r.c.before, H.vstr(0))
  t:expect(H.frames(r) == 0, 'frames=%d', H.frames(r))
end)

H.test('T78', 'search_star_pattern', function(t)
  t:parity(H.scenario({ opts = SEARCH, prepare = prep('SHORT', { start = 'TOP' }), steps = { '*' } }))
end)

H.test('T79', 'wheel_under_pointer', function(t)
  local r = H.scenario({
    opts = WHEEL,
    native_opts = NO_WHEEL,
    prepare = function(c)
      H.fixture('SHORT')
      c.other = api.nvim_get_current_win()
      vim.cmd('vsplit')
      c.cur = api.nvim_get_current_win()
      api.nvim_win_call(c.other, function() H.start('MID') end)
      H.start('MID')
    end,
    arm = function(c)
      local col = api.nvim_win_get_position(c.other)[2]
      assert(OTHER_WIN_COL >= col and OTHER_WIN_COL < col + api.nvim_win_get_width(c.other),
        'pointer column is not over the other window')
      c.other_before = H.vstr(c.other)
    end,
    steps = { H.mouse('wheel', 'down', WHEEL_ROW, OTHER_WIN_COL) },
    after = function(c)
      c.x.other = H.vstr(c.other)
      c.x.cur = H.vstr(c.cur)
      c.x.focus_kept = api.nvim_get_current_win() == c.cur
    end,
  })
  t:parity(r)
  t:expect(r.plugin.x.focus_kept, 'focus moved')
  t:expect(r.native.x.other ~= r.native.c.other_before, 'reference wheel did not scroll the other window')
end)

H.test('T80', 'wheel_accumulates', function(t)
  local steps = H.rep(H.mouse('wheel', 'down', WHEEL_ROW, 10), 20, 10)
  local r = H.scenario({ opts = WHEEL, native_opts = NO_WHEEL, prepare = prep('SHORT'), steps = steps })
  t:parity(r)
  t:expect(H.reversals(r.plugin, 'top') == 0 and H.reversals(r.plugin, 'lnum') == 0, 'reversals top=%d lnum=%d',
    H.reversals(r.plugin, 'top'), H.reversals(r.plugin, 'lnum'))
end)

H.test('T108', 'nowrap_wide_char_at_right_edge_no_hscroll', function(t)
  local LINES, TAB_AT = 3000, 112
  for _, col in ipairs({ TAB_AT, TAB_AT + 1 }) do
    local r = H.scenario({
      prepare = function()
        local lines = {}
        for i = 1, LINES do
          lines[i] = i % 2 == 0 and ('a'):rep(130) or (('b'):rep(TAB_AT) .. '\tc')
        end
        api.nvim_buf_set_lines(0, 0, -1, false, lines)
        vim.wo.number = true
        H.start({ topline = 1000, lnum = 1010, col = col, curswant = col })
      end,
      steps = { '<C-D>' },
    })
    t:parity(r, 'col ' .. col)
    t:expect(H.frames(r.plugin) >= 3, 'col %d: frames=%d', col, H.frames(r.plugin))
    for _, s in ipairs(r.plugin.rec) do t:expect(s.left == 0, 'col %d: leftcol=%d in a record', col, s.left) end
  end
end)
