# smoothie.nvim — project instructions

Neovim-only Lua reimplementation of vim-smoothie (smooth scrolling). Tool-neutral: applies to any coding agent working here. These rules add to the global ones; on a genuine conflict, this file wins for this repo.

## Layout

- `plugin/smoothie.lua`: load guard, version check, legacy `g:smoothie_*` options, `<Plug>` mappings, `:Smoothie`. Must stay cheap: it must not load `smoothie.engine` or `smoothie.view`.
- `lua/smoothie/init.lua`: config, validation, mappings, the always-on `vim.on_key` recorder, public API.
- `lua/smoothie/engine.lua`: native oracle, animation records, timer, frames, exact landing, interrupt rules.
- `lua/smoothie/view.lua`: screen-row geometry; reads window state, never changes it.
- `lua/smoothie/health.lua`: `:checkhealth smoothie`.
- `autoload/smoothie.vim`: vim-smoothie compat shims (`smoothie#do` and friends).
- `doc/smoothie.txt`: the user-facing reference. Keep it in sync with behavior changes.
- `README.md` (English) and `docs/README.ko.md` (Korean): the same content in two languages.
- `tests/`: headless suite (`tests/run.lua`, `tests/harness.lua`, `tests/cases/*.lua`).
- `bench/`: benchmark harness and `bench/run.sh`, compared against upstream vim-smoothie.

## Invariants

- Landing parity: after any mapped command, the final state must equal what the native command gives: all 8 `winsaveview()` keys, mode, buffer text, `'scroll'`, jumplist, `@/`, `v:hlsearch`, registers, fold state. A change that breaks parity is a bug, even if the animation looks better.
- The target is computed by running the real command (`:normal!`) and reading the view back; never re-implement Vim motion logic when the oracle can answer.
- Distances are screen rows (`nvim_win_text_height`), never buffer lines.
- Never set an option that fires `OptionSet` and never fire or suppress autocmds on the user's behalf, except the opt-in `quiet` mode: it adds `WinScrolled`/`CursorMoved` to the animated window's `'eventignorewin'` and must leave one event with the cumulative change when the animation ends. Temporary option changes use `noautocmd` and are restored exactly; quiet removes only the events it added.
- Leave caller-visible state as found: `v:count`, `'belloff'`, `'scrolloff'`.
- Idle footprint: no timer armed and no autocmds in augroup `smoothie` when nothing animates. Augroup `smoothie_restore` may hold quiet-mode restorers only after the animated window was switched or closed without autocmds.
- Supported: Neovim 0.10, 0.11 and 0.12. The 0.12 `max_height` path is only an optimization; behavior must match on all three.

## Commands

Run the suite on all three versions before calling a change done. Each run takes about 4 minutes.

```sh
nvim --headless --clean -c "luafile tests/run.lua"
/path/to/nvim-0.11/bin/nvim --headless --clean -c "luafile tests/run.lua"
/path/to/nvim-0.10/bin/nvim --headless --clean -c "luafile tests/run.lua"
```

- `SMOOTHIE_TEST=<lua pattern>` runs only tests whose `"<id> <name>"` matches (a Lua pattern, not a regex).
- Output: one `ok|FAIL|RESIDUAL <id> <name>` line per test; exit code 1 on any FAIL. `RESIDUAL` tests reproduce documented limitations and never fail the suite.
- Benchmark: `UPSTREAM=/path/to/vim-smoothie bench/run.sh` (see README).

## Testing rules

- Drive tests from the real main loop (the harness coroutine resumed by `vim.defer_fn`). Never use `vim.wait`: mappings, `WinScrolled` and redraw do not run inside it.
- Every behavioral fix gets a behavior-named regression test that fails without the fix. Check that it does.
- Compare against a native reference run (plugin mappings removed, same inputs and timings), not against hand-written expected numbers.
- Claims about native Vim/Neovim behavior must be verified by running Neovim with no plugin.

## Style

- Idiomatic Lua, 2-space indent, `local M = {}` modules, hoisted callbacks. Per-frame code must not allocate closures or option tables.
- No comments unless the why is non-obvious; the non-obvious whys here are usually Neovim internals — name the C function or behavior they depend on.
- User-facing docs: `README.md` and `doc/smoothie.txt` are English (the help file in Vim help format, 78 columns); `docs/README.ko.md` is the Korean translation of `README.md`. Change both READMEs together.
- Comparison numbers in the READMEs must not depend on the animation length (`duration`, `easing`): landing accuracy, time to the first frame and CPU per frame, not total animation time or CPU per command.
