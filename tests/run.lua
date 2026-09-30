-- Usage: nvim --headless --clean -c "luafile tests/run.lua"
--   SMOOTHIE_TEST=<lua pattern>  run only tests whose "<id> <name>" matches
--   SMOOTHIE_TEST_FULL=1         full parity matrix
--   SMOOTHIE_TEST_RTP=<dir>      plugin root to test (default: the repository root)
--   SMOOTHIE_TEST_VERBOSE=1      list every failed case of multi-case tests
--   SMOOTHIE_TEST_STARTUP_BUDGET_MS=<ms>  startup budget of plugin/smoothie.lua (default 1.5)
local TESTS = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h')
local ROOT = vim.env.SMOOTHIE_TEST_RTP or vim.fn.fnamemodify(TESTS, ':h')
local CASES = {
  'a_config', 'b_parity', 'c_chaining', 'd_key_interrupts', 'e_scripted', 'f_visual', 'g_external',
  'h_windows', 'i_modes', 'j_events', 'k_guards', 'l_compat', 'm_quality', 'residuals',
}

vim.o.lines, vim.o.columns = 50, 120
vim.opt.rtp:prepend(ROOT)
local H = dofile(TESTS .. '/harness.lua')
H.ROOT = ROOT
vim.cmd('runtime! plugin/smoothie.lua')
for _, name in ipairs(CASES) do
  assert(loadfile(TESTS .. '/cases/' .. name .. '.lua'))(H)
end
H.out(string.format('# smoothie.nvim tests: NVIM %s (%s), plugin root %s', tostring(vim.version()), vim.v.progpath, ROOT))
H.main(vim.env.SMOOTHIE_TEST)
