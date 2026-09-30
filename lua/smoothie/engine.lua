-- Animation engine: native oracle, per-window animation records, frames, exact landing.
local api, fn, uv = vim.api, vim.fn, vim.uv
local view = require('smoothie.view')

local E = { reent = 0 }

local AUG = api.nvim_create_augroup('smoothie', { clear = true })
local AUG_RESTORE = api.nvim_create_augroup('smoothie_restore', { clear = false })
local NS = api.nvim_create_namespace('smoothie')
local QUIET_VIEW, QUIET_ALL = 'WinScrolled', 'WinScrolled,CursorMoved'
local MAXCOL = vim.v.maxcol
local MAX_REPLAY = 16
local FRACTION_MULT = 16384
local CTRL_E, CTRL_Y = '\5', '\25'
local FRAME = { n = true, v = true, V = true, ['\22'] = true }
local ALLOWED = { n = true, v = true, V = true, ['\22'] = true, i = true, R = true }
local IGNORE = { [vim.keycode('<MouseMove>')] = true, [vim.keycode('<Ignore>')] = true, [''] = true }
local EMPTY_CMD = vim.keycode('<Cmd>') .. '\r'
local DIGIT = {}
for d = 1, 9 do DIGIT[tostring(d)] = true end
local VIEW_KEYS = { 'topline', 'topfill', 'skipcol', 'leftcol' }
local ALL_KEYS = { 'topline', 'topfill', 'skipcol', 'leftcol', 'lnum', 'col', 'coladd', 'curswant' }
local CURSOR_MARK = { invalidate = true }
local TOP_MARK = { right_gravity = false, invalidate = true }
local DETAILS = { details = true }

local cfg
local anims, resume = {}, {}
local epoch, hooks_on, timer, pending = 0, false, nil, false

local NORM = { cmd = 'normal', bang = true, args = { '' } }
local REPLAY = {
  cmd = 'normal',
  bang = true,
  args = { '' },
  mods = { keepjumps = true, keeppatterns = true, silent = true, emsg_silent = true },
}
local BELLOFF_ALL = { cmd = 'set', args = { 'belloff=all' }, mods = { noautocmd = true } }
local E0 = {}

local function counted(key)
  return setmetatable({}, {
    __index = function(t, n)
      local s = n .. key
      t[n] = s
      return s
    end,
  })
end
local DOWN, UP = counted(CTRL_E), counted(CTRL_Y)

local land, snap, tick_all, hooks

local function now() return uv.hrtime() / 1e6 end

local function rnd(x)
  if x >= 0 then return math.floor(x + 0.5) end
  return -math.floor(-x + 0.5)
end

local function same(a, b, keys)
  for i = 1, #keys do
    local k = keys[i]
    if a[k] ~= b[k] then return false end
  end
  return true
end

local function has_item(list, item) return (',' .. list .. ','):find(',' .. item .. ',', 1, true) ~= nil end

-- The items of the comma-separated `list` that are not in `items`.
local function without(list, items)
  local out = ''
  for item in list:gmatch('[^,]+') do
    if not has_item(items, item) then out = out == '' and item or (out .. ',' .. item) end
  end
  return out
end

local function normal(keys)
  NORM.args[1] = keys
  E.reent = E.reent + 1
  local ok, err = pcall(api.nvim_cmd, NORM, E0)
  E.reent = E.reent - 1
  -- nvim_cmd() skips the cleanup that ends a failed command line, which can turn the next error
  -- at the top level into a discarded exception (not shown, not ending a macro or mapping).
  -- An empty command line does that cleanup.
  if not ok then api.nvim_exec2('', E0) end
  return ok, err
end

local function exec(keys)
  local ok, err = normal(keys)
  if not ok then error(err, 0) end
end

-- The counted commands run here leave their count in v:count for the rest of the caller's
-- callback, where its next scroll() would pick it up; a counted empty <Cmd> puts it back.
-- Not <Ignore>: a count skips it and goes to the <Esc> that ends :normal!, leaving Visual mode.
local function keep_count(count)
  if vim.v.count ~= count then normal((count > 0 and tostring(count) or '') .. EMPTY_CMD) end
end

-- Runs keys natively in the caller's input stream, right after the current mapping. There a beep
-- or an error drops the rest of a macro or mapping, which :normal! would keep.
local function feed(keys) api.nvim_feedkeys(keys, 'ni', false) end

local function echo_err(err)
  local msg = tostring(err):gsub('^.-(E%d+:)', '%1')
  vim.v.errmsg = msg
  api.nvim_echo({ { msg, 'ErrorMsg' } }, true, E0)
end

local function silent_normal(keys)
  REPLAY.args[1] = keys
  E.reent = E.reent + 1
  pcall(api.nvim_cmd, REPLAY, E0)
  E.reent = E.reent - 1
end

local function set_option(cmd, name, value)
  api.nvim_cmd({ cmd = cmd, args = { name .. '=' .. value }, mods = { noautocmd = true } }, E0)
end

local function get_eiw(win, scope)
  return api.nvim_get_option_value('eventignorewin', { win = win, scope = scope or 'local' })
end

local function set_eiw(win, value, cmd)
  api.nvim_win_call(win, function() set_option(cmd or 'setlocal', 'eventignorewin', value) end)
end

-- A buffer that leaves a window without autocmds keeps the window's options, ours included, for
-- its next display (buflist_setfpos(), get_winopts()): in that window, and in any window without
-- saved options of its own for the buffer (find_wininfo()), also once that window is closed
-- (win_free() keeps its entry). So the restorer lasts until it runs in that window or the buffer
-- is wiped out, and SafeState catches that window showing the buffer again without autocmds.
local function restore_on_display(a, set)
  local win, buf, keep = a.win, a.buf, a.eiw
  local enter, safe
  local function restore(w)
    if get_eiw(w) == set then set_eiw(w, keep) end
  end
  enter = api.nvim_create_autocmd('BufWinEnter', {
    group = AUG_RESTORE,
    buffer = buf,
    callback = function()
      local w = api.nvim_get_current_win()
      restore(w)
      if w ~= win then return end
      api.nvim_del_autocmd(safe)
      return true
    end,
  })
  if not api.nvim_win_is_valid(win) then return end
  safe = api.nvim_create_autocmd('SafeState', {
    group = AUG_RESTORE,
    callback = function()
      if not (api.nvim_win_is_valid(win) and api.nvim_buf_is_valid(buf)) then return true end
      if api.nvim_win_get_buf(win) ~= buf then return end
      restore(win)
      api.nvim_del_autocmd(enter)
      return true
    end,
  })
end

-- Quiet mode: the window ignores the events that each frame would fire; the main loop fires them
-- once the value is back, WinScrolled with the change since its last WinScrolled. CursorMoved is
-- ignored only for a motion that moves the cursor: a move made just before the motion, in the same
-- callback, is first seen by the main loop's next check, which would report it into the ignored
-- event (normal_check_cursor_moved() takes the new position either way).
local function quiet_on(a, pre, r)
  local win, T = a.win, a.T
  local p = r and r.prev
  if p and p.quiet_cm and p.buf == a.buf then
    a.start_lnum, a.start_col, a.seen_lnum, a.seen_col = p.start_lnum, p.start_col, p.seen_lnum, p.seen_col
  else
    a.start_lnum, a.start_col, a.seen_lnum, a.seen_col = pre.lnum, pre.col, pre.lnum, pre.col
  end
  local c = api.nvim_win_get_cursor(win)
  a.quiet_cm = c[1] ~= T.lnum or c[2] ~= T.col or a.start_lnum ~= T.lnum or a.start_col ~= T.col
  local keep = get_eiw(win)
  local add = without(a.quiet_cm and QUIET_ALL or QUIET_VIEW, keep)
  if add == '' then return end
  a.eiw, a.eiw_add, a.eiw_global = keep, add, get_eiw(win, 'global')
  a.eiw_set = keep == '' and add or (keep .. ',' .. add)
  set_eiw(win, a.eiw_set)
end

-- A window made without autocmds copies the options of the one it is made from when it shows the
-- same buffer (win_init()), where on_inherit() cannot see it.
local function restore_copies(a, set)
  for _, w in ipairs(api.nvim_list_wins()) do
    local b = anims[w]
    if w ~= a.win and not (b and b.eiw_set) and api.nvim_win_get_buf(w) == a.buf and get_eiw(w) == set then
      set_eiw(w, a.eiw)
    end
  end
end

-- A value that something else changed meanwhile keeps that change, without our events: a script's
-- `:setlocal eventignorewin+=` or `-=`, or `:set` (vim.wo), which also sets the window's global
-- value from ours.
local function quiet_off(a)
  local set, win, add = a.eiw_set, a.win, a.eiw_add
  a.eiw_set = nil
  if not api.nvim_buf_is_valid(a.buf) then return end
  if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= a.buf then
    restore_on_display(a, set)
  else
    local v = get_eiw(win)
    local want = v == set and a.eiw or without(v, add)
    if want ~= v then set_eiw(win, want) end
    local g = get_eiw(win, 'global')
    local want_g = g == a.eiw_global and g or without(g, add)
    if want_g ~= g then set_eiw(win, want_g, 'setglobal') end
  end
  restore_copies(a, set)
end

-- The main loop fires CursorMoved for a cursor away from where its last check saw it
-- (normal_check_cursor_moved()); those checks ran while the event was ignored, so a cursor that
-- stopped where the last one saw it would go unreported.
local function report_cursor(a)
  local win = a.win
  if not a.quiet_cm or win ~= api.nvim_get_current_win() or api.nvim_win_get_buf(win) ~= a.buf then return end
  if not FRAME[api.nvim_get_mode().mode] then return end
  local l, c = fn.line('.'), fn.col('.') - 1
  if l == a.seen_lnum and c == a.seen_col and (l ~= a.start_lnum or c ~= a.start_col) then
    api.nvim_exec_autocmds('CursorMoved', { buffer = a.buf, modeline = false })
  end
end

-- Runs f with the current window's 'scrolloff' at so, without firing OptionSet.
local function with_scrolloff(so, f)
  local keep = api.nvim_get_option_value('scrolloff', { scope = 'local' })
  set_option('setlocal', 'scrolloff', so)
  local ok, err = pcall(f)
  set_option('setlocal', 'scrolloff', keep)
  if not ok then error(err, 0) end
end

-- A typed search or jump key opens folds at its target before Neovim computes the view;
-- under :normal! it does not ('foldopen' needs KeyTyped), and :normal! validates the view
-- before each command. So find the target silently, open its folds, and go back.
local function open_target_folds(cmd)
  local v = fn.winsaveview()
  silent_normal(cmd)
  local c = fn.winsaveview()
  if c.lnum ~= v.lnum or c.col ~= v.col then normal('zv') end
  fn.winrestview(v)
end

local function native(win, cmd, zv, stream)
  if stream then
    if zv then open_target_folds(cmd) end
    feed(cmd)
    return
  end
  local ok, err
  api.nvim_win_call(win, function()
    if zv then open_target_folds(cmd) end
    ok, err = normal(cmd)
  end)
  if not ok then echo_err(err) end
end

local function guarded(win)
  local o = { win = win }
  if api.nvim_get_option_value('scrollbind', o) or api.nvim_get_option_value('cursorbind', o) then return true end
  if has_item(vim.o.foldopen, 'all') then return true end
  return has_item(vim.o.foldclose, 'all') and api.nvim_get_option_value('foldenable', o)
end

-- Text columns that can show the cursor without horizontal scrolling; nil with 'wrap'.
-- This validates w_botline, so it must run before the oracle: the redraw after a command
-- re-checks the view only when it finds w_botline changed.
local function nowrap_cols(win)
  if api.nvim_get_option_value('wrap', { win = win }) then return nil end
  return view.text_cols(win) - api.nvim_get_option_value('sidescrolloff', { win = win })
end

local function horizontal_unsafe(cols, D, T)
  return cols ~= nil and (D.leftcol > 0 or T.leftcol > 0 or math.max(D.curswant, T.curswant) >= cols)
end

local function append(list, item)
  local t = { unpack(list) }
  t[#t + 1] = item
  return t
end

local function velocity(a, t)
  local u = (t - a.t0) / a.dur
  if u >= 1 then return 0 end
  return a.s0 * a.n * (1 - u) ^ (a.n - 1) / a.dur
end

local function del_marks(a)
  if api.nvim_buf_is_valid(a.buf) then
    api.nvim_buf_del_extmark(a.buf, NS, a.mark)
    api.nvim_buf_del_extmark(a.buf, NS, a.top_mark)
  end
end

local function forget(a)
  if anims[a.win] == a then anims[a.win] = nil end
  resume[a.win] = nil
  del_marks(a)
  if a.eiw_set then quiet_off(a) end
end

local function abort(a, err)
  pcall(land, a, 'api')
  forget(a)
  return 'smoothie: ' .. tostring(err)
end

local function unease(q, n) return 1 - (1 - q) ^ (1 / n) end

local function next_wake(a, t)
  local best, p = 1, a.p
  local S = math.abs(a.s0)
  if S > 0 then
    local k = math.floor(S * p + 0.5)
    if k < S then best = math.min(best, unease((k + 0.5) / S, a.n)) end
  end
  local C = math.abs(a.dc)
  if C > 0 then
    local m = math.floor(C * p + 0.5)
    if m < C then best = math.min(best, unease((m + 0.5) / C, a.n)) end
  end
  return math.max(a.t0 + best * a.dur, t + a.dt)
end

local function on_timer()
  if pending then return end
  pending = true
  vim.schedule(tick_all)
end

local function arm()
  local wake
  for _, a in pairs(anims) do
    if not wake or a.wake < wake then wake = a.wake end
  end
  if not wake then
    if timer then timer:stop() end
    return
  end
  timer = timer or uv.new_timer()
  timer:start(math.max(0, math.ceil(wake - now())), 0, on_timer)
end

-- The layout can change under an animation (virtual lines added by another plugin), so
-- rows measured at the start no longer lead exactly to the target: never pass it.
local function past(dir, l, target) return (dir > 0 and l > target) or (dir < 0 and l < target) end

-- In a 'nowrap' window a character that ends past the text columns (a <Tab>, a wide character)
-- would scroll horizontally: take the one before it.
local function fit_col(win, l, col, cols)
  local vc = fn.virtcol({ l, col }, 1)
  if vc[2] <= cols or vc[1] <= 1 then return col end
  return math.max(1, fn.virtcol2col(win, l, vc[1] - 1))
end

-- In Visual mode the main loop stretches the selection over closed folds (foldAdjustVisual()):
-- a cursor ending the selection goes to the end of its fold's last line, one starting it to
-- column 0. Putting it there directly keeps that move from looking like an external one.
local function visual_fold_pos(l, col)
  local vl = fn.line('v')
  if l > vl or (l == vl and col >= fn.col('v') - 1) then
    local e = fn.foldclosedend(l)
    if e < 0 then return l, col end
    local text = fn.getline(e)
    local c = #text
    if c > 0 and vim.o.selection == 'old' then c = c - 1 + vim.str_utf_start(text, c) end
    return e, c
  end
  local s = fn.foldclosed(l)
  if s < 0 then return l, col end
  return s, 0
end

-- Cursor channel: put the cursor on the line at window row rc of view v, inside the
-- 'scrolloff' band so that Neovim never scrolls because of it.
local function place(a, v, rc)
  local so, h = a.so, a.h
  if 2 * so >= h - 1 then return end
  if rc < 0 then
    rc = 0
  elseif rc > h - 1 then
    rc = h - 1
  end
  local win, T = a.win, a.T
  local tl = view.fold_start(T.lnum)
  local l = view.line_at_row(win, v, rc)
  if past(a.dc, l, tl) then l = tl end
  if not view.cursor_ok(win, v, l, so, h) then
    local l2
    if view.row_of(win, v, l) < so or (l == v.topline and v.skipcol > 0) then
      l2 = view.next_line(l)
    else
      l2 = view.prev_line(l)
    end
    local outside = l2 < 1 or l2 > api.nvim_buf_line_count(a.buf)
    if outside or past(a.dc, l2, tl) or not view.cursor_ok(win, v, l2, so, h) then return end
    l = l2
  end
  if l == view.fold_start(v.lnum) then return end
  local lnum, col, add = T.lnum, T.col, T.coladd
  if l ~= tl then
    local c = math.max(1, fn.virtcol2col(win, l, a.want_vcol))
    if a.cols then c = fit_col(win, l, c, a.cols) end
    lnum, col, add = l, c - 1, 0
  end
  fn.setpos('.', { 0, lnum, col + 1, add, a.cw1 })
end

-- The cursor can end a frame inside a closed fold either placed there or pushed there by <C-E>.
local function fit_visual_fold(a)
  local l, c = fn.line('.'), fn.col('.') - 1
  local l2, c2 = visual_fold_pos(l, c)
  if l2 ~= l or c2 ~= c then fn.setpos('.', { 0, l2, c2 + 1, 0, a.cw1 }) end
end

-- Arguments of frame_body, which is hoisted so that frames allocate no closures.
local F, F_want, F_dcur

local function frame_body()
  local a = F
  local win = a.win
  a.so = api.nvim_get_option_value('scrolloff', a.wopt)
  local v = fn.winsaveview()
  local delta = F_want - a.applied
  if delta ~= 0 then
    local units = 0
    if a.linestep then
      -- A correction by Neovim can apply more rows than the curve asks for: never scroll back.
      if view.below(v, a.T) == (delta > 0) then units = view.units_for(win, v, delta, a.T) end
    else
      local rest = view.dist(win, v, a.T)
      units = (rest > 0) == (delta > 0) and math.min(math.abs(delta), math.abs(rest)) or 0
    end
    if units > 0 then
      exec(delta > 0 and DOWN[units] or UP[units])
      local v2 = fn.winsaveview()
      a.applied = a.applied + view.dist(win, v, v2)
      v = v2
    end
  end
  place(a, v, a.c0 + F_dcur - a.applied)
  if a.vfold then fit_visual_fold(a) end
  fn.winline()
  local v3 = fn.winsaveview()
  if not same(v3, v, VIEW_KEYS) then a.applied = a.applied + view.dist(win, v, v3) end
  a.last_top, a.last_lnum, a.last_col = fn.line('w0'), v3.lnum, v3.col
end

-- Applies the frame for time t. Returns true when the motion is complete.
local function frame(a, t)
  local u = (t - a.t0) / a.dur
  if u > 1 then u = 1 end
  local p = 1 - (1 - u) ^ a.n
  local dcur = rnd(a.dc * p)
  a.p = p
  F, F_want, F_dcur = a, rnd(a.s0 * p), dcur
  api.nvim_win_call(a.win, frame_body)
  F = nil
  return u >= 1 or (a.applied == a.s0 and dcur == a.dc)
end

local function settle_to(T)
  local c = fn.winsaveview()
  if not same(c, T, VIEW_KEYS) then
    fn.winrestview(T)
  elseif not same(c, T, ALL_KEYS) then
    if T.curswant ~= MAXCOL then fn.setpos('.', { 0, T.lnum, T.col + 1, T.coladd, T.curswant + 1 }) end
    if not same(fn.winsaveview(), T, ALL_KEYS) then fn.winrestview(T) end
  end
end

-- Neovim resizes a window keeping the cursor's relative row (scroll_to_fraction()). The resize
-- was applied to the displayed view; this is the view it would have given the target.
local function resized_target(a)
  local win, T = a.win, a.T
  local h = fn.winheight(win)
  local h0 = a.h - (api.nvim_win_get_height(win) - h)
  local keeps_row = vim.o.splitkeep == 'cursor' or api.nvim_win_get_config(win).relative ~= ''
  if not keeps_row or h0 <= 1 or h <= 0 or (h >= api.nvim_buf_line_count(a.buf) and T.topline == 1) then
    return T
  end
  local fraction = math.floor((a.wrow * FRACTION_MULT + FRACTION_MULT / 2) / h0)
  local wrow = math.floor((fraction * h - 1) / FRACTION_MULT)
  local top = view.resized_top(win, T, wrow, h)
  return {
    topline = top,
    topfill = top == T.topline and T.topfill or 0,
    skipcol = 0,
    leftcol = T.leftcol,
    lnum = T.lnum,
    col = T.col,
    coladd = T.coladd,
    curswant = T.curswant,
  }
end

-- Lands an unstable target the way Neovim reached it: from the base view, replay the commands.
local function replay(a)
  local belloff = vim.o.belloff
  api.nvim_cmd(BELLOFF_ALL, E0)
  fn.winrestview(a.base)
  -- Natively the base had been drawn, so w_botline was exact when the commands ran.
  fn.line('w$')
  for _, c in ipairs(a.cmds) do
    silent_normal(c)
    fn.winline()
  end
  set_option('set', 'belloff', belloff)
  if not same(fn.winsaveview(), a.T, ALL_KEYS) then fn.winrestview(a.T) end
end

-- Lands on T. A target that only Neovim's own scrolling reaches moves once it is validated
-- afresh; it is then landed by replay. `strict` validates afresh even when the view is already
-- T, as a following key's replay may start from here.
local function settle(a, strict)
  local T = a.T
  if strict then
    fn.winrestview(T)
  else
    settle_to(T)
  end
  if not a.base then return end
  fn.winline()
  a.stable = same(fn.winsaveview(), T, ALL_KEYS)
  if not a.stable then replay(a) end
end

local function mark_row(buf, id)
  local m = api.nvim_buf_get_extmark_by_id(buf, NS, id, DETAILS)
  if m[1] then return m[1], m[3].invalid == true end
end

-- Moves the target with the text an edit shifted, the way Neovim moves a window's view: a line
-- replaced in place (the line count unchanged) keeps its number, and a deleted top line gives
-- way to the line above the deletion. The marks are gone when another plugin cleared all
-- namespaces.
local function anchor(a)
  local T = a.T
  local in_place = api.nvim_buf_line_count(a.buf) == a.lines
  local row, invalid = mark_row(a.buf, a.mark)
  if row and not (invalid and in_place) then T.lnum = row + 1 end
  row, invalid = mark_row(a.buf, a.top_mark)
  if row and not (invalid and in_place) then
    local top = invalid and math.max(1, row) or row + 1
    if top ~= T.topline then T.topline, T.topfill = top, 0 end
  end
end

land = function(a, how)
  local win = a.win
  if anims[win] ~= a then return end
  anims[win] = nil
  local showing = api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == a.buf
  if showing and how == 'anchor' then anchor(a) end
  del_marks(a)
  if a.eiw_set then quiet_off(a) end
  if not showing then return end
  local T = a.T
  api.nvim_win_call(win, function()
    if how == 'anchor' then
      fn.winrestview(T)
      a.base = nil
    elseif api.nvim_win_get_height(win) ~= a.h then
      fn.winrestview(resized_target(a))
      a.base = nil
    elseif how == 'api' or not FRAME[api.nvim_get_mode().mode] then
      if not same(fn.winsaveview(), T, ALL_KEYS) then fn.winrestview(T) end
    elseif api.nvim_get_option_value('scrolloff', a.wopt) ~= a.so0 then
      -- Natively 'scrolloff' changed after the command, which leaves the view as it was.
      with_scrolloff(a.so0, function() settle(a, how == 'snap') end)
    else
      settle(a, how == 'snap')
    end
  end)
end

-- Lands exactly, remembering the displayed view and velocity so that a smoothie command
-- following in the same main-loop turn continues the motion from what is on screen.
snap = function(a)
  local win = a.win
  if not (api.nvim_win_is_valid(win) and api.nvim_win_get_buf(win) == a.buf) then return forget(a) end
  local display, landed
  api.nvim_win_call(win, function() display = fn.winsaveview() end)
  local v = velocity(a, now())
  land(a, 'snap')
  api.nvim_win_call(win, function() landed = fn.winsaveview() end)
  resume[win] = {
    display = display,
    v = v,
    epoch = epoch,
    chain = { base = a.base, cmds = a.cmds, stable = a.stable, landed = landed },
    prev = a,
  }
end

local function rebase(a)
  local T = a.T
  forget(a)
  api.nvim_win_call(a.win, function()
    local c = fn.winsaveview()
    fn.winrestview({
      topline = T.topline,
      topfill = T.topfill,
      skipcol = T.skipcol,
      leftcol = T.leftcol,
      lnum = c.lnum,
      col = c.col,
      coladd = c.coladd,
      curswant = c.curswant,
    })
  end)
end

local function line_w0() return fn.line('w0') end

local function step(a, t)
  if E._fault then E._fault(a) end
  local win = a.win
  if not api.nvim_win_is_valid(win) or api.nvim_win_get_buf(win) ~= a.buf then return forget(a) end
  local m = api.nvim_get_mode().mode
  if not FRAME[m] or (win ~= api.nvim_get_current_win() and m ~= 'n') then return land(a, 'api') end
  if api.nvim_buf_get_changedtick(a.buf) ~= a.tick then return land(a, 'anchor') end
  if api.nvim_win_get_height(win) ~= a.h or api.nvim_win_get_width(win) ~= a.w then return land(a, 'api') end
  local c = api.nvim_win_get_cursor(win)
  if c[1] ~= a.last_lnum or c[2] ~= a.last_col then return rebase(a) end
  if api.nvim_win_call(win, line_w0) ~= a.last_top then return land(a) end
  if frame(a, t) then return land(a) end
  if a.epoch == epoch then pcall(api.nvim__redraw, { win = win, flush = true }) end
  a.epoch = epoch
  a.wake = next_wake(a, t)
end

tick_all = function()
  pending = false
  local t, err = now(), nil
  local cur = cfg.quiet and anims[api.nvim_get_current_win()]
  for _, a in pairs(anims) do
    if a.wake <= t + 1 then
      local ok, e = xpcall(step, debug.traceback, a, t)
      if not ok then
        local msg = abort(a, e)
        err = err or msg
      end
    end
  end
  arm()
  if cur and anims[cur.win] ~= cur then report_cursor(cur) end
  if err then error(err, 0) end
end

local function on_safe()
  epoch = epoch + 1
  for w in pairs(resume) do
    resume[w] = nil
  end
  if next(anims) == nil then
    hooks(false)
  elseif cfg.quiet then
    -- normal_check() fires SafeState after its CursorMoved check, which saw this cursor.
    local a = anims[api.nvim_get_current_win()]
    if a and a.eiw_set and a.quiet_cm then a.seen_lnum, a.seen_col = fn.line('.'), fn.col('.') - 1 end
  end
end

-- A window copies an animating window's options, ours included, when split from it (win_init())
-- or when it shows its buffer (get_winopts() takes them from a window displaying the buffer).
-- Put back before it leaves the buffer or closes, which saves them for the buffer's next display.
local function restore_copy(w)
  local value = get_eiw(w)
  for _, a in pairs(anims) do
    if a.eiw_set == value and a.win ~= w then
      set_eiw(w, a.eiw)
      return
    end
  end
end

local function on_winclosed(ev)
  local win = tonumber(ev.match)
  local a = anims[win]
  if a then
    forget(a)
  elseif cfg.quiet then
    restore_copy(win)
  end
  resume[win] = nil
end

local function on_bufleave()
  local w = api.nvim_get_current_win()
  local a = anims[w]
  if a then
    land(a)
  elseif cfg.quiet then
    restore_copy(w)
  end
end

local function on_inherit() restore_copy(api.nvim_get_current_win()) end

hooks = function(on)
  if on == hooks_on then return end
  hooks_on = on
  if not on then
    api.nvim_clear_autocmds({ group = AUG })
    return
  end
  api.nvim_create_autocmd('SafeState', { group = AUG, callback = on_safe })
  api.nvim_create_autocmd('WinClosed', { group = AUG, callback = on_winclosed })
  api.nvim_create_autocmd('BufLeave', { group = AUG, callback = on_bufleave })
  if cfg.quiet then api.nvim_create_autocmd({ 'WinNew', 'BufWinEnter' }, { group = AUG, callback = on_inherit }) end
end

-- Brings the window from the target back to the displayed view D by scrolling, as the frames
-- do. winrestview() would repaint the whole window on the next redraw, and have Neovim validate
-- afresh a view that it reaches only by scrolling (near the end with 'scrolloff').
local function scroll_back(a, D)
  local rows = -a.s0
  if rows ~= 0 then
    local units = a.linestep and view.units_for(a.win, a.T, rows, D) or math.abs(rows)
    if units > 0 then exec((rows > 0 and DOWN or UP)[units]) end
  end
  local v = fn.winsaveview()
  if not same(v, D, VIEW_KEYS) then
    fn.winrestview(D)
  elseif not same(v, D, ALL_KEYS) then
    fn.setpos('.', { 0, D.lnum, D.col + 1, D.coladd, D.curswant == MAXCOL and MAXCOL or D.curswant + 1 })
  end
end

-- Starts animating record a (window state at its target a.T) from the displayed view D.
local function begin(a, D, pre, cmd, r)
  local win, T = a.win, a.T
  local h = api.nvim_win_get_height(win)
  a.h, a.w, a.n, a.dt = h, api.nvim_win_get_width(win), cfg.n, cfg.dt
  a.wopt = { win = win }
  local cap = math.max(1, math.floor(cfg.max_travel * h))
  local far = false
  api.nvim_win_call(win, function()
    a.linestep = api.nvim_get_option_value('wrap', a.wopt) and not api.nvim_get_option_value('smoothscroll', a.wopt)
    a.so = api.nvim_get_option_value('scrolloff', a.wopt)
    a.so0 = a.so
    a.c1 = view.row_of(win, T, T.lnum)
    local s = view.dist(win, D, T, cap)
    if s then
      a.c0 = view.row_of(win, D, D.lnum)
    else
      far = true
      local up = view.below(D, T)
      -- Without 'smoothscroll' a wrapped window scrolls whole lines: count the lines of cap rows.
      local units = a.linestep and math.max(1, view.units_for(win, T, up and -cap or cap, D)) or cap
      exec((up and UP or DOWN)[units])
      D = fn.winsaveview()
      s = view.dist(win, D, T)
      a.c0 = a.c1
    end
    a.s0 = s
  end)
  a.dc = a.s0 + a.c1 - a.c0
  local mag = math.max(math.abs(a.s0), math.abs(a.c1 - a.c0))
  if mag <= 1 and not far then return false end
  local v = (r and not far) and r.v or 0
  local dur = cfg.duration * math.min(1, math.sqrt(mag / h))
  if v ~= 0 and a.s0 ~= 0 and (v > 0) == (a.s0 > 0) then dur = math.min(dur, a.n * math.abs(a.s0) / math.abs(v)) end
  a.dur = math.max(dur, a.dt)
  local ch = r and r.chain
  if ch and ch.base and not ch.stable and same(pre, ch.landed, ALL_KEYS) then
    a.base, a.cmds = ch.base, append(ch.cmds, cmd)
  else
    a.base, a.cmds = pre, { cmd }
  end
  if #a.cmds > MAX_REPLAY then a.base, a.cmds = nil, nil end
  if not far then api.nvim_win_call(win, function() scroll_back(a, D) end) end
  a.want_vcol = math.min(T.curswant, MAXCOL - 1) + 1
  a.cw1 = T.curswant == MAXCOL and MAXCOL or T.curswant + 1
  local buf = a.buf
  a.tick = api.nvim_buf_get_changedtick(buf)
  a.lines = api.nvim_buf_line_count(buf)
  a.mark = api.nvim_buf_set_extmark(buf, NS, T.lnum - 1, 0, CURSOR_MARK)
  a.top_mark = api.nvim_buf_set_extmark(buf, NS, T.topline - 1, 0, TOP_MARK)
  a.applied, a.t0 = 0, now() - a.dt
  anims[win] = a
  hooks(true)
  if cfg.quiet then quiet_on(a, pre, r) end
  local ok, done = xpcall(frame, debug.traceback, a, now())
  if not ok then error(abort(a, done), 0) end
  if done then
    land(a)
    return true
  end
  a.epoch = epoch
  a.wake = next_wake(a, now())
  arm()
  return true
end

local function run(win, cmd, o)
  local mode = api.nvim_get_mode().mode
  if not ALLOWED[mode:sub(1, 1)] then return false end
  if anims[win] then snap(anims[win]) end
  local r = resume[win]
  resume[win] = nil
  if r and r.epoch ~= epoch then r = nil end
  local cur = api.nvim_get_current_win()
  local stream = o.feed and win == cur
  if not o.animate or not FRAME[mode] or (win ~= cur and mode ~= 'n') or guarded(win) then
    native(win, cmd, o.zv, stream)
    return false
  end
  local buf = api.nvim_win_get_buf(win)
  local tick = api.nvim_buf_get_changedtick(buf)
  local cols = nowrap_cols(win)
  -- With keys pending and no motion to continue, a command that fails or does nothing (a
  -- beep) runs again in the input stream, for its effect on those keys; the oracle's own run
  -- stays silent.
  local rerun = stream and not r and fn.state('m') ~= ''
  local belloff = rerun and vim.o.belloff
  if rerun then api.nvim_cmd(BELLOFF_ALL, E0) end
  local pre, T, wrow, ok, err
  api.nvim_win_call(win, function()
    if o.zv then open_target_folds(cmd) end
    pre = fn.winsaveview()
    ok, err = normal(cmd)
    wrow = fn.winline() - 1
    T = fn.winsaveview()
  end)
  if rerun then set_option('set', 'belloff', belloff) end
  if not ok then
    if stream then
      feed(cmd)
    else
      echo_err(err)
    end
    return false
  end
  if rerun and same(pre, T, ALL_KEYS) then
    feed(cmd)
    return false
  end
  if
    api.nvim_get_current_win() ~= cur
    or not api.nvim_win_is_valid(win)
    or api.nvim_win_get_buf(win) ~= buf
    or api.nvim_buf_get_changedtick(buf) ~= tick
    or api.nvim_get_mode().mode ~= mode
  then
    return false
  end
  local D = r and r.display or pre
  if horizontal_unsafe(cols, D, T) then return false end
  local vfold = mode ~= 'n' and api.nvim_get_option_value('foldenable', { win = win })
  return begin({ win = win, buf = buf, T = T, wrow = wrow, cols = cols, vfold = vfold }, D, pre, cmd, r)
end

--- Runs `cmd` (raw keys, count included) natively in `win` and animates the view change.
--- o.animate: animation allowed by the caller; o.zv: open folds at the target the way a
--- typed search or jump key does ('foldopen'); o.feed: `cmd` stands for the key being
--- processed, so running it natively means running it in the caller's input stream.
function E.run(win, cmd, o)
  local count = vim.v.count
  local prev = anims[win]
  local started = run(win, cmd, o)
  keep_count(count)
  -- No key led here while prev animates (on_key lands it first), so a motion that ends here ends
  -- outside both a key and a timer tick.
  if prev and not anims[win] then report_cursor(prev) end
  return started
end

--- Called by the on_key listener, only while an animation exists.
function E.on_key(key)
  if IGNORE[key] or DIGIT[key] then return end
  local kt = fn.keytrans(key)
  local mouse = kt:find('Mouse>', 1, true) or kt:find('Drag>', 1, true) or kt:find('Release>', 1, true)
    or kt:find('ScrollWheel', 1, true)
  for _, a in pairs(anims) do
    if mouse then
      forget(a)
    else
      snap(a)
    end
  end
end

function E.active() return next(anims) ~= nil end

function E.is_animating(win)
  if win == nil then return next(anims) ~= nil end
  if win == 0 then win = api.nvim_get_current_win() end
  return anims[win] ~= nil
end

function E.stop()
  local count = vim.v.count
  local cur = anims[api.nvim_get_current_win()]
  for _, a in pairs(anims) do
    land(a)
  end
  keep_count(count)
  for w in pairs(resume) do
    resume[w] = nil
  end
  arm()
  hooks(false)
  if cur then report_cursor(cur) end
end

function E.configure(c) cfg = c end

function E.idle()
  return next(anims) == nil
    and next(resume) == nil
    and #api.nvim_get_autocmds({ group = AUG }) == 0
    and not (timer and timer:is_active())
end

local paste = vim.paste
vim.paste = function(...)
  E.stop()
  return paste(...)
end

return E
