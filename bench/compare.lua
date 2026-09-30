-- Side-by-side comparison of bench.lua / bench_ui.lua result files.
--
--   nvim --headless --clean -l compare.lua BASE.json OTHER.json [MORE.json ...]
--
-- For every scenario present in BASE, prints one row per file with the median
-- metrics, and for non-base files the ratio vs BASE for cpu and duration
-- ("x0.25" = 4x less).  Flags (!) incorrect landings, timeouts, failed j-checks.
-- Set COMPARE_FIELDS=ui to show UI-traffic fields (bench_ui.lua results).
local files = arg
assert(#files >= 1, 'usage: nvim -l compare.lua BASE.json [OTHER.json ...]')

local function load(p)
  local r = vim.json.decode(table.concat(vim.fn.readfile(p), '\n'))
  local by = {}
  for _, s in ipairs(r.summary) do by[s.id] = s end
  r.by = by
  return r
end
local res = {}
for i, p in ipairs(files) do res[i] = load(p) end
local base = res[1]
local ui = vim.env.COMPARE_FIELDS == 'ui'

local function ratio(a, b)
  if not a or not b or a == 0 then return '    -' end
  return ('x%.2f'):format(b / a)
end

local out = {}
local function p(s) out[#out + 1] = s end
for i, r in ipairs(res) do
  p(('[%d] %s  (%s)  runs=%d idle=%.2fus/ms matchparen=%s'):format(i, r.label, files[i], r.runs_per_scenario,
    r.idle_cpu_us_per_ms or 0, tostring(r.matchparen)))
end
if ui then
  p(('%-15s %-3s %6s %7s %8s %9s %8s %8s %6s %6s'):format('scenario', '#', 'frames', 'flushes', 'cells', 'bytes',
    'dur_ms', 'cpu_ms', 'cpu', 'ok'))
else
  p(('%-15s %-3s %6s %8s %7s %8s %8s %7s %4s %6s %6s %5s'):format('scenario', '#', 'frames', 'dur_ms', 'first',
    'cpu_ms', 'us/intv', 'maxgap', 'rev', 'cpu', 'dur', 'ok'))
end
for _, s0 in ipairs(base.summary) do
  for i, r in ipairs(res) do
    local s = r.by[s0.id]
    if s then
      local flag = ''
      if s.correct < s.runs then flag = flag .. ' !landing' end
      if s.timeouts > 0 then flag = flag .. ' !timeout' end
      if s.j_ok < s.runs then flag = flag .. ' !j' end
      local okcol = ('%d/%d'):format(s.correct, s.runs)
      if ui then
        local u = s.ui or {}
        p(('%-15s [%d] %6.0f %7.0f %8.0f %9.0f %8.1f %8.2f %6s %6s%s'):format(i == 1 and s.id or '', i, s.frames,
          u.flushes or 0, u.cells or 0, u.bytes or 0, s.dur_ms, s.cpu_us / 1000,
          i == 1 and '' or ratio(s0.cpu_us, s.cpu_us), okcol, flag))
      else
        p(('%-15s [%d] %6.0f %8.1f %7.1f %8.2f %8.0f %7.1f %4.0f %6s %6s %5s%s'):format(i == 1 and s.id or '', i,
          s.frames, s.dur_ms, s.first_ms, s.cpu_us / 1000, s.tick_cpu_us, s.max_gap_ms,
          s.reversals_top + s.reversals_lnum, i == 1 and '' or ratio(s0.cpu_us, s.cpu_us),
          i == 1 and '' or ratio(s0.dur_ms, s.dur_ms), okcol, flag))
      end
    end
  end
end
io.stdout:write(table.concat(out, '\n') .. '\n')
