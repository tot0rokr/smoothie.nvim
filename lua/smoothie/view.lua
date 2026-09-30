-- Screen-row geometry. Reads window state only. Every function must run with `win` as the
-- current window (inside nvim_win_call): fold state is window-local.
local api, fn = vim.api, vim.fn

local M = {}

local th = api.nvim_win_text_height
local HAS_MAXH = fn.has('nvim-0.12') == 1
-- Without max_height a capped distance is measured in full, so spans beyond this many
-- lines are declared far without measuring.
local FAR_LINES = 4000
-- Evaluated in Vimscript: converting getwininfo() to Lua would copy the window's whole w: dict.
local TEXT_COLS = 'map(getwininfo(%d), "v:val.width - v:val.textoff")[0]'

function M.fold_start(l)
  local s = fn.foldclosed(l)
  return s > 0 and s or l
end

local function fold_end(l)
  local e = fn.foldclosedend(l)
  return e > 0 and e or l
end

function M.next_line(l) return fold_end(l) + 1 end

function M.prev_line(l) return M.fold_start(l - 1) end

local function fill_above(win, l)
  return th(win, { start_row = l - 1, end_row = l - 1, end_vcol = 0 }).all
end

local function rows(win, l)
  return th(win, { start_row = l - 1, end_row = l - 1, start_vcol = 0 }).all
end

-- Rows of line l (1 for a closed fold) and the filler rows above it, in one measurement.
local function line_rows(win, l)
  local r = th(win, { start_row = l - 1, end_row = l - 1 })
  return r.all - r.fill, r.fill
end

--- Columns of text per screen row: the width without the number, sign and fold columns.
--- Like getwininfo(), this validates w_botline.
function M.text_cols(win) return api.nvim_eval(TEXT_COLS:format(win)) end

--- True when view b starts further down than view a.
function M.below(a, b)
  if b.topline ~= a.topline then return b.topline > a.topline end
  if b.skipcol ~= a.skipcol then return b.skipcol > a.skipcol end
  return b.topfill < a.topfill
end

local function rows_down(win, a, b, cap)
  local o = { start_row = a.topline - 1, end_row = b.topline - 1, end_vcol = b.skipcol }
  local sub = 0
  if a.skipcol > 0 or a.topfill == 0 then
    o.start_vcol = a.skipcol
  else
    sub = fill_above(win, a.topline) - a.topfill
  end
  if cap then
    if HAS_MAXH then
      o.max_height = cap + sub + b.topfill + 1
    elseif b.topline - a.topline > FAR_LINES then
      return nil
    end
  end
  local r = th(win, o)
  local d = r.all - sub - b.topfill
  if cap and (d > cap or (HAS_MAXH and r.end_row < o.end_row)) then return nil end
  return d
end

--- Signed screen rows from view a to view b (positive: b is further down).
--- With `cap`, returns nil when the distance exceeds it.
function M.dist(win, a, b, cap)
  if a.topline == b.topline and a.skipcol == b.skipcol and a.topfill == b.topfill then return 0 end
  if M.below(a, b) then return rows_down(win, a, b, cap) end
  local d = rows_down(win, b, a, cap)
  return d and -d
end

--- 0-based window row of the first text row of line l in view v.
function M.row_of(win, v, l)
  local s = M.fold_start(l)
  if s < v.topline then return 0 end
  if s == v.topline then return v.skipcol == 0 and v.topfill or 0 end
  return th(win, { start_row = v.topline - 1, start_vcol = v.skipcol, end_row = s - 1, end_vcol = 0 }).all
    + v.topfill
end

--- Buffer line (fold start for folds) whose rows contain 0-based window row r of view v.
function M.line_at_row(win, v, r)
  if r < v.topfill then return v.topline end
  if HAS_MAXH then
    return th(win, { start_row = v.topline - 1, start_vcol = v.skipcol, max_height = r - v.topfill + 1 }).end_row
      + 1
  end
  local last = api.nvim_buf_line_count(0)
  local l = v.topline
  local bottom = v.topfill + th(win, { start_row = l - 1, end_row = l - 1, start_vcol = v.skipcol }).all
  while bottom <= r do
    local nx = M.next_line(l)
    if nx > last then break end
    l = nx
    bottom = bottom + th(win, { start_row = l - 1, end_row = l - 1 }).all
  end
  return l
end

--- Conservative copy of update_topline's 'scrolloff' checks: true when putting the cursor
--- on line l keeps view v unchanged.
function M.cursor_ok(win, v, l, so, h)
  if 2 * so >= h - 1 then return false end
  if l < v.topline or (l == v.topline and v.skipcol > 0) then return false end
  if not (v.topline == 1 and v.skipcol == 0) and M.row_of(win, v, l) < so then return false end
  local bot = fn.line('w$')
  if bot < api.nvim_buf_line_count(0) then
    local e = fold_end(l)
    if e > bot or (so > 0 and (e == bot or th(win, { start_row = e, end_row = bot - 1 }).all < so)) then
      return false
    end
  end
  return true
end

-- Rows of line l before the one showing byte col, counted like plines_win_col(): a character
-- starting exactly at the end of the first row still counts as the first row.
local function rows_before_col(win, l, col)
  if not api.nvim_get_option_value('wrap', { win = win }) then return 0 end
  local vcol = fn.virtcol({ l, col + 1 }, 1)[1] - 1
  if vcol <= M.text_cols(win) then return 0 end
  return th(win, { start_row = l - 1, end_row = l - 1, start_vcol = 0, end_vcol = vcol + 1 }).all - 1
end

--- Topline that scroll_to_fraction() picks when a window resized to height h shows the cursor
--- of view v on row `wrow`.
function M.resized_top(win, v, wrow, h)
  local l = v.lnum
  local fill = fill_above(win, l)
  local sline = wrow - fill - rows_before_col(win, l, v.col)
  if sline >= 0 then sline = math.min(sline, h - fill - rows(win, l)) end
  if sline <= 0 then return M.fold_start(l) end
  repeat
    l = M.fold_start(l)
    if l == 1 then return 1 end
    l = l - 1
    sline = sline - math.min(rows(win, l), h) - (l == v.topline and v.topfill or fill_above(win, l))
  until sline <= 0 or l == 1
  if sline < 0 then return M.next_line(l) end
  return sline > 0 and 1 or M.fold_start(l)
end

--- Number of <C-E> (need > 0) or <C-Y> (need < 0) units that bring view v nearest to `need`
--- rows without passing target view T. Only meaningful for 'wrap' without 'smoothscroll',
--- where a unit is one filler row or one whole line or fold.
function M.units_for(win, v, need, T)
  local want = math.abs(need)
  local top, fill, got, units = v.topline, v.topfill, 0, 0
  local top_rows, top_fill = line_rows(win, top)
  local last = api.nvim_buf_line_count(0)
  while top ~= T.topline or fill ~= T.topfill do
    local ur, ntop, nfill, nrows, nfa
    if need > 0 then
      if fill > 0 then
        ur, ntop, nfill, nrows, nfa = 1, top, fill - 1, top_rows, top_fill
      else
        local e = fold_end(top)
        if e >= last then break end
        ntop = e + 1
        nrows, nfa = line_rows(win, ntop)
        ur, nfill = top_rows, nfa
      end
    else
      if fill < top_fill then
        ur, ntop, nfill, nrows, nfa = 1, top, fill + 1, top_rows, top_fill
      else
        if top <= 1 then break end
        ntop = M.prev_line(top)
        nrows, nfa = line_rows(win, ntop)
        ur, nfill = nrows, 0
      end
    end
    if got + ur - want > want - got then break end
    got, top, fill, top_rows, top_fill = got + ur, ntop, nfill, nrows, nfa
    if ur > 0 then units = units + 1 end
  end
  return units
end

return M
