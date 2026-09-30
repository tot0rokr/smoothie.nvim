local api, fn = vim.api, vim.fn

local M = {}

M.default_keys = {
  '<C-D>', '<C-U>', '<C-F>', '<C-B>', '<PageDown>', '<PageUp>', '<S-Down>', '<S-Up>',
  'z+', 'z^', 'zt', 'z<CR>', 'z.', 'zz', 'z-', 'zb',
}

local JUMP_KEYS = { 'gg', 'G' }
local SEARCH_KEYS = { 'n', 'N', '*', '#', 'g*', 'g#' }
local WHEEL_KEYS = { '<ScrollWheelDown>', '<ScrollWheelUp>' }
local MODES = { 'n', 'x' }
local DESC = 'smoothie '
local EASING = { linear = 1, quadratic = 2, cubic = 3, quartic = 4, quintic = 5 }
local MAX_EASING = 5
local MAX_FPS = 240
local SNIFF_BYTES = 8192
local IS_SEARCH, IS_JUMP = {}, {}
for _, k in ipairs(SEARCH_KEYS) do IS_SEARCH[k] = true end
for _, k in ipairs(JUMP_KEYS) do IS_JUMP[k] = true end

-- A fresh table each time, so no copy is needed: vim.deepcopy() is the costliest step at startup.
local function defaults()
  return {
    enabled = true,
    keys = { unpack(M.default_keys) },
    jumps = false,
    search = false,
    mouse = false,
    duration = 400,
    easing = 'cubic',
    fps = 60,
    max_travel = 2,
    quiet = false,
    max_filesize = false,
    exclude_binary = true,
    exclude_filetypes = {},
    exclude_buftypes = { 'terminal', 'prompt' },
  }
end

local function list_of_strings(v)
  if type(v) ~= 'table' or not vim.islist(v) then return false end
  for _, s in ipairs(v) do
    if type(s) ~= 'string' then return false end
  end
  return true
end

local STRINGS = { list_of_strings, 'list of strings' }
local VALIDATORS = {
  enabled = 'boolean',
  keys = STRINGS,
  jumps = 'boolean',
  search = 'boolean',
  mouse = 'boolean',
  duration = { function(v) return type(v) == 'number' and v >= 0 end, 'non-negative number' },
  easing = {
    function(v)
      return EASING[v] ~= nil or (type(v) == 'number' and v % 1 == 0 and v >= 1 and v <= MAX_EASING)
    end,
    'linear|quadratic|cubic|quartic|quintic or integer 1..5',
  },
  fps = { function(v) return type(v) == 'number' and v >= 1 and v <= MAX_FPS end, 'number 1..240' },
  max_travel = { function(v) return type(v) == 'number' and v > 0 end, 'positive number' },
  quiet = 'boolean',
  max_filesize = { function(v) return v == false or (type(v) == 'number' and v > 0) end, 'false or positive number' },
  exclude_binary = 'boolean',
  exclude_filetypes = STRINGS,
  exclude_buftypes = STRINGS,
}

local validate = fn.has('nvim-0.11') == 1 and vim.validate
  or function(name, value, validator, message) vim.validate({ [name] = { value, validator, message } }) end

M.config = defaults()
M.skipped = {}
M._configured = false
M._typed = true

local mapped = {}

--- Internal: whether this Neovim has 'eventignorewin', which the quiet option needs.
function M._quiet_supported() return fn.exists('+eventignorewin') == 1 end

local function engine_config(c)
  return {
    n = EASING[c.easing] or c.easing,
    dt = 1000 / c.fps,
    duration = c.duration,
    max_travel = c.max_travel,
    quiet = c.quiet and M._quiet_supported(),
  }
end

local engine_mod
local function engine()
  if not engine_mod then
    engine_mod = require('smoothie.engine')
    engine_mod.configure(engine_config(M.config))
  end
  return engine_mod
end

local function off(v) return v == false or v == 0 end
local function truthy(v) return v ~= nil and not off(v) end

local function has_item(list, item) return (',' .. list .. ','):find(',' .. item .. ',', 1, true) ~= nil end

--- Internal: how the global switches disable smoothie, or nil.
function M._disabled()
  if truthy(vim.g.neovide) or truthy(vim.g.started_by_firenvim) then
    return 'automatically for this UI (g:neovide or g:started_by_firenvim)'
  end
  if off(vim.g.smoothie_enabled) then return 'by g:smoothie_enabled' end
  if not M.config.enabled then return 'by the enabled option (:Smoothie)' end
end

-- A NUL byte in the first bytes of the file, as git decides that a file is binary. Neovim keeps no
-- record of NUL bytes it read, so the file is read once per buffer and the answer kept in
-- b:smoothie_binary, which a user may also set.
local function binary(buf)
  if vim.bo[buf].binary then return true end
  local b = vim.b[buf]
  if b.smoothie_binary == nil then
    local name, head = api.nvim_buf_get_name(buf), nil
    local f = name ~= '' and io.open(name, 'rb')
    if f then
      head = f:read(SNIFF_BYTES)
      f:close()
    end
    b.smoothie_binary = head ~= nil and head:find('\0', 1, true) ~= nil
  end
  return b.smoothie_binary
end

local function too_large(buf, limit) return api.nvim_buf_get_offset(buf, api.nvim_buf_line_count(buf)) > limit end

---@param win? integer default: the current window
function M.enabled(win)
  win = win or 0
  local c = M.config
  if M._disabled() or off(vim.w[win].smoothie_enabled) then return false end
  local buf = api.nvim_win_get_buf(win)
  if off(vim.b[buf].smoothie_enabled) then return false end
  local bo = vim.bo[buf]
  if vim.tbl_contains(c.exclude_buftypes, bo.buftype) or vim.tbl_contains(c.exclude_filetypes, bo.filetype) then
    return false
  end
  if c.max_filesize and too_large(buf, c.max_filesize) then return false end
  return not (c.exclude_binary and binary(buf))
end

local function resolve_win(win)
  if not win or win == 0 or not api.nvim_win_is_valid(win) then return api.nvim_get_current_win() end
  return win
end

local function prefixed(count, keys) return (count > 0 and tostring(count) or '') .. keys end

local function scripted() return not M._typed and fn.state('m') == '' end

--- Mapping path: the callback behind every mapping and <Plug>.
function M._map(lhs, o)
  o = o or {}
  local win = resolve_win(o.win)
  local cmd = prefixed(o.count or vim.v.count, vim.keycode(lhs))
  local animate = M.enabled(win) and fn.reg_executing() == '' and not scripted()
  local fo = vim.o.foldopen
  local zv = M._typed
    and ((IS_SEARCH[lhs] and has_item(fo, 'search')) or (IS_JUMP[lhs] and has_item(fo, 'jump')))
    or false
  return engine().run(win, cmd, { animate = animate, zv = zv, feed = true })
end

--- smoothie#do(): raw keys, no <>-notation.
function M._raw(cmd)
  local win = api.nvim_get_current_win()
  local animate = M.enabled(win) and fn.reg_executing() == '' and not scripted()
  return engine().run(win, prefixed(vim.v.count, cmd), { animate = animate, zv = false })
end

--- Runs `keys` (<>-notation) natively in a window and animates the resulting view change.
---@param keys string
---@param opts? { count?: integer, win?: integer }
---@return boolean started
function M.scroll(keys, opts)
  opts = opts or {}
  local win = resolve_win(opts.win)
  local cmd = prefixed(opts.count or vim.v.count, vim.keycode(keys))
  local animate = M.enabled(win) and fn.reg_executing() == ''
  return engine().run(win, cmd, { animate = animate, zv = false })
end

---@param win? integer nil: any window; 0: the current window
function M.is_animating(win)
  local E = package.loaded['smoothie.engine']
  return E ~= nil and E.is_animating(win)
end

function M.stop()
  local E = package.loaded['smoothie.engine']
  if E then E.stop() end
end

function M.enable() M.config.enabled = true end
function M.disable() M.config.enabled = false end
function M.toggle() M.config.enabled = not M.config.enabled end

-- The global mapping of lhs, or nil. maparg() reports the current buffer's own mapping first,
-- but smoothie only maps globally.
local function global_map(mode, lhs)
  if fn.maparg(lhs, mode) == '' then return nil end
  local m = fn.maparg(lhs, mode, false, true)
  if m.buffer ~= 1 then return m end
  for _, g in ipairs(api.nvim_get_keymap(mode)) do
    if g.lhs == m.lhs then return g end
  end
end

local function ours(m, lhs) return m ~= nil and m.desc == DESC .. lhs end

-- Neovim's own default mappings (such as Visual * and #) are described as ":help <tag>-default".
local function builtin(m) return m.desc ~= nil and m.desc:find('^:help %S+%-default$') ~= nil end

local function unmap()
  for _, m in ipairs(mapped) do
    if ours(global_map(m[1], m[2]), m[2]) then api.nvim_del_keymap(m[1], m[2]) end
  end
  mapped = {}
  M.skipped = {}
end

local function map(lhs, rhs)
  for _, mode in ipairs(MODES) do
    local m = global_map(mode, lhs)
    if m and not ours(m, lhs) then
      if not builtin(m) then M.skipped[#M.skipped + 1] = mode .. ' ' .. lhs end
    else
      api.nvim_set_keymap(mode, lhs, '', { callback = rhs, noremap = true, silent = true, desc = DESC .. lhs })
      mapped[#mapped + 1] = { mode, lhs }
    end
  end
end

local function map_keys(keys)
  for _, lhs in ipairs(keys) do
    map(lhs, function() M._map(lhs) end)
  end
end

---@param opts? table
function M.setup(opts)
  opts = opts or {}
  validate('opts', opts, 'table')
  for k, v in pairs(opts) do
    local spec = VALIDATORS[k]
    if not spec then error(('smoothie: unknown option "%s"'):format(tostring(k)), 0) end
    if type(spec) == 'table' then
      validate(k, v, spec[1], spec[2])
    else
      validate(k, v, spec)
    end
  end
  unmap()
  local c = defaults()
  -- Validated: every table value is a list of strings.
  for k, v in pairs(opts) do
    c[k] = type(v) == 'table' and { unpack(v) } or v
  end
  M.config = c
  if engine_mod then engine_mod.configure(engine_config(c)) end
  map_keys(c.keys)
  if c.jumps then map_keys(JUMP_KEYS) end
  if c.search then map_keys(SEARCH_KEYS) end
  if c.mouse then
    for _, lhs in ipairs(WHEEL_KEYS) do
      map(lhs, function() M._map(lhs, { win = fn.getmousepos().winid, count = 0 }) end)
    end
  end
  M._configured = true
end

local ns = api.nvim_create_namespace('smoothie')
vim.on_key(function(key, typed)
  local E = package.loaded['smoothie.engine']
  if E and E.reent > 0 then return end
  M._typed = typed ~= nil and typed ~= ''
  if E and E.active() then
    local ok, err = pcall(E.on_key, key)
    if not ok then vim.schedule(function() error('smoothie: ' .. tostring(err), 0) end) end
  end
end, ns)

return M
