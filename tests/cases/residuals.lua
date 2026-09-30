local H = ...
local api = vim.api
local prep = H.prep

H.residual('R1', 'residual_so999_chain_eof', function(t)
  t:parity(H.scenario({
    opts = { jumps = true },
    prepare = prep('SHORT', { so = 999, start = { topline = 195, lnum = 218, col = 4, curswant = 4 } }),
    steps = { 'z+', 30, 'G', 30, '<C-D>', 30, '<C-D>', 30, 'z.' },
  }))
end)

H.residual('R2', 'residual_async_delete_target_line', function(t)
  t:parity(H.scenario({
    prepare = prep('SHORT', { start = { topline = 90, lnum = 100 } }),
    steps = { '<C-D>', 40, function() api.nvim_buf_set_lines(0, 123, 124, false, {}) end },
  }))
end)

-- With quiet, a key that lands an animation fires one CursorMoved for both: native fires one for
-- the <C-D> and one for the j.
H.residual('R6', 'residual_quiet_key_landing_merges_cursormoved', function(t)
  if vim.fn.exists('+eventignorewin') == 0 then return t:fail("quiet needs 'eventignorewin' (Neovim 0.11)") end
  t:parity(H.scenario({
    opts = { quiet = true },
    prepare = prep('SHORT'),
    arm = function(c)
      c.x.cm = 0
      H.au('CursorMoved', function() c.x.cm = c.x.cm + 1 end)
    end,
    steps = { '<C-D>', 40, 'j' },
  }))
end)

-- The redraw after <C-B> finds its estimate of the bottom line wrong (the cursor line is no longer
-- concealed) and validates the view again: native ends 5 lines below the target the command left.
H.residual('R7', 'residual_conceal_lines_redraw_correction', function(t)
  if vim.fn.has('nvim-0.11') == 0 then return t:fail('conceal_lines needs Neovim 0.11') end
  local ns = api.nvim_create_namespace('smoothie_test_conceal')
  local r = H.scenario({
    prepare = function()
      H.fixture('SHORT', 3000)
      for i = 3, 3000, 3 do api.nvim_buf_set_extmark(0, ns, i - 1, 0, { conceal_lines = '' }) end
      vim.wo.conceallevel = 2
      vim.wo.concealcursor = ''
      vim.o.scrolloff = 5
      H.start({ topline = 1000, lnum = 1001 })
    end,
    steps = { '<C-B>' },
  })
  t:parity(r)
  t:expect(H.reversals(r.plugin, 'top') == 0, 'topline reversals=%d', H.reversals(r.plugin, 'top'))
end)

-- With quiet, an animation whose window loses focus without a key fires no CursorMoved of its own:
-- Neovim fires CursorMoved only in the current window. Native fires one for the <C-D>.
H.residual('R8', 'residual_quiet_focus_loss_drops_cursormoved', function(t)
  if vim.fn.exists('+eventignorewin') == 0 then return t:fail("quiet needs 'eventignorewin' (Neovim 0.11)") end
  t:parity(H.scenario({
    opts = { quiet = true },
    prepare = function()
      H.fixture('SHORT')
      vim.cmd('split')
      H.start('MID')
    end,
    arm = function(c)
      c.x.cm = 0
      H.au('CursorMoved', function() c.x.cm = c.x.cm + 1 end)
    end,
    steps = { '<C-D>', 40, function() vim.cmd('wincmd j') end },
  }))
end)
