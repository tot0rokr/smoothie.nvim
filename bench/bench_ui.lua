-- UI-attached variant of bench.lua: measures what a real UI would receive.
--
--   BENCH_PLUGIN=... BENCH_OUT=/tmp/x.json nvim --headless --clean -l bench_ui.lua
--
-- This driver spawns `nvim --embed --clean -c 'luafile bench.lua'` (all
-- BENCH_* env vars are passed through, plus BENCH_UI_CHILD=1), attaches to it
-- as an ext_linegrid UI of BENCH_COLUMNS x BENCH_LINES (default 120x50), and
-- counts the redraw traffic between the child's per-run 'start'/'end' marks:
--   flushes  = screen updates the UI would paint (true "frames")
--   cells    = grid_line cells sent (proxy for terminal output volume)
--   scrolls  = grid_scroll events (cheap terminal scroll regions)
--   bytes    = raw msgpack bytes of redraw notifications
-- With a UI attached the child really renders, so its CPU numbers (cpu_us,
-- us/tick in the child's JSON) include grid rendering cost.
-- Output: $BENCH_OUT (child JSON + per-run `ui` fields) and $BENCH_OUT.txt.
local uv = vim.uv or vim.loop
local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local out = assert(vim.env.BENCH_OUT, 'BENCH_OUT is required')
local cols = tonumber(vim.env.BENCH_COLUMNS or '') or 120
local rows = tonumber(vim.env.BENCH_LINES or '') or 50

local envlist = { 'BENCH_UI_CHILD=1' }
for k, v in pairs(vim.fn.environ()) do
  if k ~= 'BENCH_UI_CHILD' then envlist[#envlist + 1] = k .. '=' .. v end
end

local stdin, stdout = uv.new_pipe(false), uv.new_pipe(false)
local exited, exit_code = false, nil
local handle = uv.spawn('nvim', {
  args = { '--embed', '--clean', '-c', 'luafile ' .. vim.fn.fnameescape(here .. '/bench.lua') },
  stdio = { stdin, stdout, 2 },
  env = envlist,
}, function(code)
  exit_code = code
  exited = true
end)
assert(handle, 'failed to spawn nvim --embed')

local function ext(_, data) return data end
local session = vim.mpack.Session({ unpack = vim.mpack.Unpacker({ ext = { [0] = ext, [1] = ext, [2] = ext } }) })
local pack = vim.mpack.encode

local cur -- stats of the run currently between 'start' and 'end'
local per_run = {}
local attached = false

local function on_redraw(batches, nbytes)
  if not cur then return end
  cur.bytes = cur.bytes + nbytes
  for _, b in ipairs(batches) do
    local name = b[1]
    if name == 'flush' then
      cur.flushes = cur.flushes + (#b - 1)
      cur.flush_t[#cur.flush_t + 1] = uv.hrtime() / 1e6
    elseif name == 'grid_line' then
      for i = 2, #b do
        local cells = b[i][4]
        for _, c in ipairs(cells) do cur.cells = cur.cells + (c[3] or 1) end
      end
    elseif name == 'grid_scroll' then
      cur.scrolls = cur.scrolls + (#b - 1)
    elseif name == 'grid_clear' then
      cur.clears = cur.clears + (#b - 1)
    end
  end
end

local function on_mark(tag, data)
  if tag == 'start' then
    cur = { id = data.id, run = data.run, bytes = 0, flushes = 0, cells = 0, scrolls = 0, clears = 0,
      flush_t = {}, t0 = uv.hrtime() / 1e6 }
  elseif tag == 'end' and cur then
    local ft = cur.flush_t
    local maxgap, prev = 0, cur.t0
    for _, t in ipairs(ft) do
      maxgap = math.max(maxgap, t - prev)
      prev = t
    end
    cur.paint_dur_ms = #ft > 0 and (ft[#ft] - cur.t0) or 0
    cur.paint_max_gap_ms = maxgap
    cur.flush_t, cur.t0 = nil, nil
    per_run[#per_run + 1] = cur
    cur = nil
  end
end

local partial = 0 -- bytes of a message that straddles read chunks
stdout:read_start(function(err, data)
  assert(not err, err)
  if not data then return end
  local pos, len = 1, #data
  while pos <= len do
    local start = pos
    local typ, id_or_cb, method_or_err, args
    typ, id_or_cb, method_or_err, args, pos = session:receive(data, pos)
    local nbytes = partial + (pos - start)
    partial = typ == nil and nbytes or 0
    if typ == 'notification' then
      if method_or_err == 'redraw' then
        on_redraw(args, nbytes)
      elseif method_or_err == 'bench_mark' then
        on_mark(args[1], args[2])
      end
    elseif typ == 'response' then
      if type(id_or_cb) == 'function' then id_or_cb(method_or_err, args) end
    elseif typ == 'request' then
      -- no requests expected; reply with an error so the child never blocks
      stdin:write(session:reply(id_or_cb) .. pack('unsupported') .. pack(vim.mpack.NIL))
    end
  end
end)

local req = session:request(function(e)
  assert(e == nil or e == vim.mpack.NIL, 'nvim_ui_attach failed: ' .. vim.inspect(e))
  attached = true
end)
stdin:write(req .. pack('nvim_ui_attach') .. pack({ cols, rows, { ext_linegrid = true, rgb = true } }))

local ok = vim.wait(3 * 3600 * 1000, function() return exited end, 50)
assert(ok and attached, 'child did not finish')
if exit_code ~= 0 then
  io.stderr:write('child exited with code ' .. tostring(exit_code) .. '\n')
  os.exit(exit_code or 1)
end

-- merge into child's JSON
local res = vim.json.decode(table.concat(vim.fn.readfile(out), '\n'))
local key = function(r) return r.id .. '#' .. r.run end
local ui_by = {}
for _, u in ipairs(per_run) do ui_by[key(u)] = u end
for _, r in ipairs(res.runs) do r.ui = ui_by[key(r)] end

local function median(xs)
  table.sort(xs)
  local n = #xs
  if n == 0 then return 0 end
  if n % 2 == 1 then return xs[(n + 1) / 2] end
  return (xs[n / 2] + xs[n / 2 + 1]) / 2
end
local UIF = { 'flushes', 'cells', 'scrolls', 'clears', 'bytes', 'paint_dur_ms', 'paint_max_gap_ms' }
local lines = { ('# %s  [UI attached %dx%d]  child cpu includes grid rendering'):format(res.label, cols, rows),
  ('%-14s %6s %7s %8s %9s %7s %8s %9s %8s %8s %7s'):format('scenario', 'frames', 'flushes', 'cells', 'bytes',
    'scrolls', 'dur_ms', 'paintgap', 'cpu_ms', 'us/tick', 'correct') }
for _, s in ipairs(res.summary) do
  local acc = {}
  for _, f in ipairs(UIF) do acc[f] = {} end
  for _, r in ipairs(res.runs) do
    if r.id == s.id and r.ui then
      for _, f in ipairs(UIF) do table.insert(acc[f], r.ui[f]) end
    end
  end
  s.ui = {}
  for _, f in ipairs(UIF) do s.ui[f] = median(acc[f]) end
  lines[#lines + 1] = ('%-14s %6.0f %7.0f %8.0f %9.0f %7.0f %8.1f %9.1f %8.2f %8.0f %5d/%d'):format(s.id, s.frames,
    s.ui.flushes, s.ui.cells, s.ui.bytes, s.ui.scrolls, s.dur_ms, s.ui.paint_max_gap_ms, s.cpu_us / 1000,
    s.tick_cpu_us, s.correct, s.runs)
end
res.ui_attached = { columns = cols, lines = rows }
vim.fn.writefile({ vim.json.encode(res) }, out)
vim.fn.writefile(lines, out .. '.txt')
io.stdout:write(table.concat(lines, '\n') .. '\n')
