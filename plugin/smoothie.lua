if vim.g.loaded_smoothie_nvim then return end
vim.g.loaded_smoothie_nvim = true

if vim.fn.has('nvim-0.10') == 0 then
  vim.notify('smoothie: requires Neovim 0.10 or later', vim.log.levels.ERROR)
  return
end

local smoothie = require('smoothie')

local function truthy(v) return v ~= nil and v ~= false and v ~= 0 end

local function legacy_opts()
  local g, opts = vim.g, {}
  if g.smoothie_remapped_commands ~= nil then
    opts.keys = g.smoothie_remapped_commands
  elseif truthy(g.smoothie_no_default_mappings) then
    opts.keys, opts.jumps = {}, false
  elseif truthy(g.smoothie_experimental_mappings) then
    opts.jumps = true
  end
  return opts
end

if not smoothie._configured then smoothie.setup(legacy_opts()) end

local PLUGS = {
  SmoothieDownwards = '<C-D>',
  SmoothieUpwards = '<C-U>',
  SmoothieForwards = '<C-F>',
  SmoothieBackwards = '<C-B>',
  Smoothie_gg = 'gg',
  Smoothie_G = 'G',
}
for name, key in pairs(PLUGS) do
  local opts = { callback = function() smoothie._map(key) end, noremap = true, silent = true, desc = 'smoothie ' .. key }
  for _, mode in ipairs({ 'n', 'x' }) do
    vim.api.nvim_set_keymap(mode, '<Plug>(' .. name .. ')', '', opts)
  end
end

local ACTIONS = { enable = smoothie.enable, disable = smoothie.disable, toggle = smoothie.toggle }
vim.api.nvim_create_user_command('Smoothie', function(a)
  local action = ACTIONS[a.args == '' and 'toggle' or a.args]
  if not action then error(('smoothie: unknown argument "%s"'):format(a.args), 0) end
  action()
end, {
  nargs = '?',
  desc = 'smoothie: enable, disable or toggle smooth scrolling',
  complete = function(lead)
    return vim.tbl_filter(function(s) return vim.startswith(s, lead) end, { 'enable', 'disable', 'toggle' })
  end,
})
