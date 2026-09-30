local M = {}

local IGNORED_GLOBALS = {
  'smoothie_update_interval',
  'smoothie_speed_constant_factor',
  'smoothie_speed_linear_factor',
  'smoothie_speed_exponentiation_factor',
  'smoothie_redraw_at_finish',
  'smoothie_break_on_reverse',
}

function M.check()
  local h = vim.health
  local smoothie = require('smoothie')
  local c = smoothie.config

  h.start('smoothie')
  if vim.fn.has('nvim-0.10') == 1 then
    h.ok('Neovim ' .. tostring(vim.version()))
  else
    h.error('Neovim 0.10 or later is required')
  end
  if vim.fn.has('nvim-0.12') == 1 then
    h.ok('nvim_win_text_height() max_height: available (distances stop early at max_travel)')
  else
    h.info('nvim_win_text_height() max_height: not available (distances are measured in full)')
  end
  if smoothie._quiet_supported() then
    h.ok("'eventignorewin': available (the quiet option works)")
  elseif c.quiet then
    h.warn("'eventignorewin': not available, so quiet = true acts as false (it needs Neovim 0.11)")
  else
    h.info("'eventignorewin': not available (the quiet option needs Neovim 0.11)")
  end

  local why = smoothie._disabled()
  if why then h.info('disabled ' .. why) end
  h.info(('enabled = %s, duration = %s ms, easing = %s, fps = %s, max_travel = %s, quiet = %s'):format(
    tostring(c.enabled), tostring(c.duration), tostring(c.easing), tostring(c.fps), tostring(c.max_travel),
    tostring(c.quiet)))
  h.info(('mapped groups: keys (%d), jumps = %s, search = %s, mouse = %s'):format(
    #c.keys, tostring(c.jumps), tostring(c.search), tostring(c.mouse)))
  h.info(('instant in: max_filesize = %s, exclude_binary = %s, exclude_filetypes = %s, exclude_buftypes = %s'):format(
    tostring(c.max_filesize), tostring(c.exclude_binary), table.concat(c.exclude_filetypes, ','),
    table.concat(c.exclude_buftypes, ',')))

  if #smoothie.skipped == 0 then
    h.ok('no key was skipped')
  else
    for _, item in ipairs(smoothie.skipped) do
      h.warn(('not mapped, already mapped elsewhere: %s'):format(item))
    end
  end

  for _, name in ipairs(IGNORED_GLOBALS) do
    if vim.g[name] ~= nil then h.warn(('g:%s is ignored by this plugin'):format(name)) end
  end

  local engine = package.loaded['smoothie.engine']
  if engine then
    h.info(('engine loaded; animating: %s; idle: %s'):format(tostring(engine.is_animating()), tostring(engine.idle())))
  else
    h.info('engine not loaded yet (no command has run)')
  end
end

return M
