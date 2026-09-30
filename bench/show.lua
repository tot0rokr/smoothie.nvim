-- Dump per-run details of one scenario from a bench.lua result file.
--   nvim --headless --clean -l show.lua RESULT.json SCENARIO_ID
-- e.g. nvim --headless --clean -l show.lua "$OUT/smoothie.nvim.json" wrapss/C-U@end
local path, id = arg[1], arg[2]
assert(path and id, 'usage: nvim -l show.lua RESULT.json SCENARIO_ID')
local r = vim.json.decode(table.concat(vim.fn.readfile(path), '\n'))
local function v(x)
  if not x then return '-' end
  return ('top=%d lnum=%d col=%d want=%d skip=%d'):format(x.topline, x.lnum, x.col, x.curswant, x.skipcol)
end
for _, run in ipairs(r.runs) do
  if run.id == id then
    print(('run %d: frames=%d dur=%.1fms first=%.1fms cpu=%.2fms tick=%.0fus rev_top=%d rev_lnum=%d correct=%s tmo=%s')
      :format(run.run, run.frames, run.dur_ms, run.first_ms, run.cpu_us / 1000, run.tick_cpu_us, run.reversals_top,
        run.reversals_lnum, tostring(run.correct), tostring(run.timed_out)))
    print('  start    ' .. v(run.start))
    print('  expected ' .. v(run.expected))
    print('  final    ' .. v(run.final))
    if run.trace then
      local parts = {}
      for _, f in ipairs(run.trace) do
        parts[#parts + 1] = ('%.0f:%d/%d/%d'):format(f[1], f[2], f[3], f[4])
      end
      print('  trace (ms:topline/lnum/skipcol) ' .. table.concat(parts, ' '))
    end
    if run.ui then print('  ui ' .. vim.inspect(run.ui, { newline = ' ', indent = '' })) end
  end
end
