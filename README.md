# smoothie.nvim

Smooth scrolling for Neovim, in Lua. A reimplementation of [vim-smoothie](https://github.com/psliwka/vim-smoothie) that moves in screen rows, lands exactly where the native command lands, and stays out of the way of your input and your other plugins.

[한국어 README](docs/README.ko.md)

- Every scroll command runs once, natively, when you press the key. The view and the cursor are then animated from what was on screen to that result, so the jumplist, marks, registers, search state, `'scroll'` and messages are the same as without the plugin.
- Distances are screen rows: closed folds, wrapped lines, virtual lines and diff filler move evenly.
- Each motion ends within `duration`, on one of five ease-out curves. The first frame is drawn in the key's own callback.
- A key typed during an animation lands it and then acts on the final state. Repeating a scroll key keeps the current speed.
- Optional `quiet` mode fires `WinScrolled` and `CursorMoved` once per motion, for plugins that react to them.
- Drop-in for vim-smoothie: its `g:smoothie_*` options, `smoothie#do()` and `<Plug>` mappings keep working.
- Neovim 0.10 or later, no dependencies. Vim is not supported.

## Compared with vim-smoothie

| Item                                         | vim-smoothie                   | smoothie.nvim     |
| -------------------------------------------- | ------------------------------ | ----------------- |
| Scrolling over closed folds                  | does not animate, jumps        | animates          |
| Scenarios landing where the native one lands | 51/52                          | 52/52             |
| Key press to first screen change             | 20.5-22.1 ms                   | 1.3 ms or less    |
| CPU per frame (average of 33 scenarios)      | 1014 µs                        | 667 µs (52% less) |
| Jitter (a frame moving backwards)            | once (`wrapss/C-U@end`)        | never             |

These are the numbers that barely depend on how long an animation is set to take. Animation time, frame count and total CPU per command do, so they are not compared. More in [Measurements](#measurements).

Why it behaves better:

- **Screen-row resolution.** vim-smoothie counts distance in buffer lines and moves with `N<C-E>` and `Nj`, which move by screen lines. Over closed folds it overshoots and jumps to the target; on wrapped lines it moves a whole line (several rows) at a time. smoothie.nvim measures rows with `nvim_win_text_height()` and moves in the same unit. With `'smoothscroll'` it moves row by row inside long wrapped lines too.
- **Exact landing.** Chained keys start from the landed native state, not from a restored view, and the target includes the view correction Neovim applies when it redraws. Targets that `winrestview()` cannot reproduce are landed by replaying the command.
- **Bounded time.** vim-smoothie's speed falls with the remaining distance, so it creeps near the target. smoothie.nvim ends every motion within `duration`, animates at most `max_travel` window heights of a far jump, and lets you pick the curve.
- **Lighter frames.** One `<C-E>`/`<C-Y>` per frame from Lua, a timer that wakes only when the rounded position changes, and nothing armed while idle.
- **No fighting.** A plugin that changes the view or layout during an animation makes it land once; it never chases a moving target. Macros, `:normal` and `feedkeys()` run instantly and synchronously.

## Requirements

- Neovim 0.10 or later. The test suite runs on 0.10.4, 0.11.4 and 0.12.5.
- `quiet` needs `'eventignorewin'` (Neovim 0.11). On 0.10 it acts as `false`.
- On 0.12 far distances stop early at `max_travel` (`nvim_win_text_height()` with `max_height`). On 0.10 and 0.11 they are measured in full, and jumps over 4000 lines are treated as far.

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'tot0rokr/smoothie.nvim',
  main = 'smoothie',
  lazy = false,
  opts = {},
}
```

Configure it with `opts` or `config`, not `keys`: lazy.nvim's `keys` handler replays the first key press as not typed, so that press would not animate. Lazy-loading is not needed; at startup the plugin only creates mappings, and the animation engine loads on the first scroll.

[vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'tot0rokr/smoothie.nvim'
```

Built-in packages:

```sh
git clone https://github.com/tot0rokr/smoothie.nvim ~/.local/share/nvim/site/pack/plugins/start/smoothie.nvim
nvim -c 'helptags ~/.local/share/nvim/site/pack/plugins/start/smoothie.nvim/doc' -c q
```

## Configuration

Without configuration the plugin maps the 16 default keys when it loads. To change options, call `setup()`, before or after the plugin loads:

```lua
require('smoothie').setup({
  duration = 300,
  jumps = true,
  quiet = true,
})
```

Each call applies its options over the defaults, not over the previous call, and replaces the mappings the previous call made. An unknown option or a wrong type raises an error.

| Option              | Type             | Default                    | Meaning                                            |
| ------------------- | ---------------- | -------------------------- | -------------------------------------------------- |
| `enabled`           | boolean          | `true`                     | Master switch                                      |
| `keys`              | `string[]`       | `default_keys`             | Keys to map, in `<>` notation. `{}` maps none      |
| `jumps`             | boolean          | `false`                    | Also map `gg` and `G`                              |
| `search`            | boolean          | `false`                    | Also map `n` `N` `*` `#` `g*` `g#`                 |
| `mouse`             | boolean          | `false`                    | Also map `<ScrollWheelDown>` and `<ScrollWheelUp>` |
| `duration`          | number, ms       | `400`                      | Time of a motion of at least one window height     |
| `easing`            | string or 1-5    | `'cubic'`                  | Ease-out curve                                     |
| `fps`               | number 1-240     | `60`                       | Frame-rate cap                                     |
| `max_travel`        | number > 0       | `2`                        | Longest animated distance, in window heights       |
| `quiet`             | boolean          | `false`                    | Fire `WinScrolled`/`CursorMoved` once per motion   |
| `max_filesize`      | bytes or `false` | `false`                    | Buffers larger than this scroll instantly          |
| `exclude_binary`    | boolean          | `true`                     | Binary buffers scroll instantly                    |
| `exclude_filetypes` | `string[]`       | `{}`                       | Filetypes that scroll instantly                    |
| `exclude_buftypes`  | `string[]`       | `{ 'terminal', 'prompt' }` | Buftypes that scroll instantly                     |

- The default `keys` are `<C-D>` `<C-U>` `<C-F>` `<C-B>` `<PageDown>` `<PageUp>` `<S-Down>` `<S-Up>` `z+` `z^` `zt` `z<CR>` `z.` `zz` `z-` `zb`.
- A motion shorter than the window height, of `r` rows, takes `duration * sqrt(r / height)`.
- `mouse` scrolls the window under the pointer; consecutive wheel events accumulate.
- A jump farther than `max_travel` is cut once, at the start, and animates the last `max_travel` window heights.
- `max_filesize` compares with the buffer's size in bytes, so unsaved and generated buffers count too. `max_filesize = 2 * 1024 * 1024` keeps files over 2 MiB instant.
- A buffer is binary when `'binary'` is set or its file has a NUL byte in the first 8 KiB, the check git uses. The file is read once per buffer and the answer kept in `b:smoothie_binary`; set that variable to decide yourself.
- Keys are mapped in Normal and Visual mode only, so `d<C-D>` and typing in Select mode stay native. A key something else already maps is left alone and listed by `:checkhealth smoothie`.

### Easing

All curves are `1 - (1 - t)^n` and differ only in `n`. A larger `n` starts faster and spends longer on the last rows, which do not show once the motion is below one row, so it feels quicker.

| `easing`           | Start speed (vs. average) | Feel                                  |
| ------------------ | ------------------------- | ------------------------------------- |
| `linear`           | 1x                        | Constant speed, abrupt stop           |
| `quadratic`        | 2x                        | Even deceleration to the end          |
| `cubic` (default)  | 3x                        | Quick start, short soft end           |
| `quartic`          | 4x                        | Most of the way in the first frames   |
| `quintic`          | 5x                        | Nearly a jump, then a soft end        |

### Quiet mode

With `quiet = true`, the animated window ignores `WinScrolled` while the animation runs, and `CursorMoved` too when the animation moves the cursor. When the motion ends, `WinScrolled` fires once with the change of the whole motion in `v:event`, and `CursorMoved` once if the cursor moved, as after a single native scroll. Keys chained into one motion give one event.

Turn it on when plugins react to these events with heavy handlers or throttled updates. render-markdown.nvim, for example, redraws on the first of a series of events only, so per-frame events leave part of the final view unrendered. The cost: scrollbars, context headers and similar plugins show the state from before the motion until the animation ends. `quiet` needs Neovim 0.11; on 0.10 it acts as `false` and `:checkhealth smoothie` warns.

Measured with a config running render-markdown.nvim, coc.nvim, context.vim, indent-blankline.nvim, vim-airline and vim-gitgutter, on NVIM 0.12.5, 120x50, `'scrolloff'` 9, default `duration`:

- `<C-F>` in a 5000-line markdown file of headings: without `quiet`, 100 ms after landing only 23-30 of the 48 visible lines were rendered (29 of 34 trials, 3 of them still at 600 ms). With `quiet`, all 48 were rendered in all 34 trials. Same on 0.11.4.
- Events per scroll: 3-17 `WinScrolled` and as many `CursorMoved` without `quiet`, one of each with it.
- `<C-D>`/`<C-U>` in a 7828-line C file: same frame count, 13-16% less Neovim CPU per animation, and child-process CPU (coc.nvim's node, the python host) halved or better.
- `<C-D>`/`<C-U>` in a 384-line markdown file with tables and code blocks: without `quiet`, the event handlers moved the view during the animation and it landed early, after about 75 ms. With `quiet` it animated to the end, about 240 ms, so it drew more frames and used 55-69% more CPU per animation.

## Commands and API

- `:Smoothie [enable|disable|toggle]`: switch the plugin; `toggle` is the default. The mappings stay; while disabled they scroll instantly.
- `:checkhealth smoothie`: Neovim features in use, why the plugin is disabled, the settings, keys left alone, ignored vim-smoothie globals, engine state.

All functions are in `require('smoothie')`:

| Function                            | Description                                                       |
| ----------------------------------- | ----------------------------------------------------------------- |
| `scroll(keys, opts?)`               | Run `keys` natively and animate the change. `true` if it started  |
| `stop()`                            | Land every animation exactly on its target                        |
| `is_animating(win?)`                | `nil`: any window; `0`: the current window                        |
| `enable()`, `disable()`, `toggle()` | Set the `enabled` option                                          |
| `enabled(win?)`                     | Whether smoothie is enabled for `win` (default: current window)   |
| `default_keys`                      | The 16 default keys                                               |
| `skipped`                           | `"<mode> <lhs>"` of keys left alone                               |

`scroll()` takes `<>` notation. Several commands in one string, like `'<C-d>zz'`, animate as one motion. `opts.count` is prefixed when greater than 0 and defaults to `vim.v.count`; `opts.win` picks another window without moving the focus.

```lua
vim.keymap.set({ 'n', 'x' }, '<Leader>d', function() require('smoothie').scroll('<C-d>zz') end)
```

`<Plug>` mappings, in Normal and Visual mode: `<Plug>(SmoothieDownwards)` (`<C-D>`), `<Plug>(SmoothieUpwards)` (`<C-U>`), `<Plug>(SmoothieForwards)` (`<C-F>`), `<Plug>(SmoothieBackwards)` (`<C-B>`), `<Plug>(Smoothie_gg)`, `<Plug>(Smoothie_G)`. Used as the whole right-hand side of a mapping, they animate and pass the count on.

## Disabling

Checked on every command, in this order; the first match runs the command natively and instantly:

1. `g:neovide` or `g:started_by_firenvim` is set to anything but `0` or `v:false` (Neovide animates scrolling itself; firenvim redraws slowly).
2. `g:smoothie_enabled` is `0` or `v:false`.
3. The `enabled` option is `false`.
4. `w:smoothie_enabled` or `b:smoothie_enabled` is `0` or `v:false`.
5. The buffer's `'buftype'` or `'filetype'` is excluded.
6. The buffer is larger than `max_filesize`.
7. `exclude_binary` is on and the buffer is binary.

Macros, `:normal`, `feedkeys()` without the `t` flag, keys at the end of a mapping's right-hand side, windows with `'scrollbind'` or `'cursorbind'`, `'foldopen'` containing `all`, `'foldclose'` set to `all` with `'foldenable'`, and `'nowrap'` windows where the cursor could scroll horizontally also run instantly.

## Migrating from vim-smoothie

Until `setup()` runs, these globals are read once at startup; `setup()` replaces them:

| Global                             | Handling                                        |
| ---------------------------------- | ----------------------------------------------- |
| `g:smoothie_enabled`               | Read on every command                           |
| `g:smoothie_remapped_commands`     | Used as `keys`; the two flags below are ignored |
| `g:smoothie_no_default_mappings`   | `keys = {}`, `jumps = false`                    |
| `g:smoothie_experimental_mappings` | `jumps = true`                                  |
| `g:smoothie_update_interval`       | Ignored, use `fps`                              |
| `g:smoothie_speed_*`               | Ignored, use `duration` and `easing`            |
| `g:smoothie_redraw_at_finish`      | Ignored, there is no final `:mode` redraw       |

- `smoothie#do("\<C-D>")` takes raw keys and prefixes `v:count`; `smoothie#downwards()`, `#upwards()`, `#forwards()` and `#backwards()` exist too. Search keys called from a Vimscript function lose `v:hlsearch` (`:help function-search-undo`); use `search = true` or `scroll()` for them.
- `<Plug>(Smoothie_gg)` and `<Plug>(Smoothie_G)`, dropped by vim-smoothie, are back.
- Fixed vim-smoothie issues: stuck or jumping over folds (#40, #20, #34), endless oscillation with context.vim and render-markdown.nvim (#45, #53), a jerky first scroll at the buffer ends (#47), `zz` after a scroll in a mapping (#46), `getchar()` loops such as vim-libmodal (#42), slow UIs and firenvim (#17, #19), a long slow tail and no speed setting (#22, #27), search motions (#33, #37), the mouse wheel (#44), per-buffer disabling (#51), the lost `<Plug>` mappings (#43).

## Limitations

- With `'scrolloff'` at least half the window, keys chained during an animation can land a few rows off. Single keys land exactly.
- A window resized during an animation can land a few rows off when Neovim reuses a row fraction saved by an earlier resize.
- A mapping whose right-hand side starts with a count, like `nmap X 5<C-D>`, scrolls instantly. Use `scroll('5<C-d>')` or a `<Plug>` mapping.
- `scroll()` and `smoothie#do()` run keys like `:normal!`, so a failing command does not end a macro. Mapped keys do end it, as Neovim does.
- With `quiet`, a key that lands an animation merges its events with the animation's, and a few scripted or `noautocmd` cases lose or keep suppressed events.
- Insert-mode `<PageUp>`/`<PageDown>` are not animated.

The full list, with the reasons, is in `:help smoothie-limitations`.

## Development

Tests (about 4-5 minutes per run):

```sh
nvim --headless --clean -c "luafile tests/run.lua"
```

- Each test prints `ok`, `FAIL` or `RESIDUAL` with its id and name, then a summary. The exit code is 1 if any test fails. `RESIDUAL` tests reproduce documented limitations and do not fail the suite.
- Every test is compared with a native reference run: the same input and timing with the plugin's mappings removed.
- Start it with another `nvim` binary to test that version; child processes use the same binary.
- Results: 0.12.5 and 0.11.4 give 134 ok, 0 FAIL, 5 RESIDUAL; 0.10.4 gives 117 ok, 0 FAIL, 5 RESIDUAL (the `quiet` tests are registered only on 0.11 and later).

| Variable                      | Effect                                                   |
| ----------------------------- | -------------------------------------------------------- |
| `SMOOTHIE_TEST=<lua pattern>` | Run only tests whose `"<id> <name>"` matches             |
| `SMOOTHIE_TEST_FULL=1`        | Extend the landing matrix (`scrolloff=999`, top of file) |
| `SMOOTHIE_TEST_RTP=<dir>`     | Plugin root to test (default: this repository)           |
| `SMOOTHIE_TEST_VERBOSE=1`     | List every failed case of multi-case tests               |

Benchmark against vim-smoothie (about 26 minutes from an empty `OUT`, 12 when the baselines are reused):

```sh
git clone https://github.com/psliwka/vim-smoothie /tmp/vim-smoothie
UPSTREAM=/tmp/vim-smoothie OUT=/tmp/smoothie.nvim-bench bench/run.sh
```

It records native and vim-smoothie baselines in `$OUT/upstream`, then smoothie.nvim runs, and writes five comparisons (`cmp-*.txt`) to `$OUT`. `nvim --headless --clean -l bench/show.lua "$OUT/smoothie.nvim.json" 'wrapss/C-U@end'` shows one scenario frame by frame.

### Measurements

Measured with `bench/run.sh` on 2026-09-30: AMD EPYC-Genoa 16 CPU, Linux 6.8, NVIM 0.12.5, `nvim --headless --clean`, 120x50 (window height 48), matchparen on, median of 5 runs per scenario. vim-smoothie `df1e324` (2022-06-10) with default settings; smoothie.nvim with `duration = 200`, `easing = 'cubic'`, `fps = 60`. Four buffers (`short`: 10000 lines; `wrap`: 5000 lines, every third 300 characters; `wrapss`: the same with `'smoothscroll'`; `folds`: 10000 lines of closed marker folds), 13 commands each, 52 scenarios.

CPU per frame is the median CPU between two consecutive frames, including Neovim's redraw and autocmds, minus the harness's idle cost:

| Buffer            | vim-smoothie | smoothie.nvim | Less CPU |
| ----------------- | ------------ | ------------- | -------- |
| `short` (11)      | 870 µs       | 546 µs        | 59%      |
| `wrap` (11)       | 934 µs       | 651 µs        | 43%      |
| `wrapss` (11)     | 1238 µs      | 804 µs        | 54%      |
| Average (33)      | 1014 µs      | 667 µs        | 52%      |

- Only scenarios both plugins animate are included; the percentage is (vim-smoothie − smoothie.nvim) / smoothie.nvim. `gg` and `G` are not mapped by default in either plugin, so they run natively.
- `folds` is left out: vim-smoothie does not animate over closed folds and jumps to the target within 1-4 frames. smoothie.nvim animates those scenarios at 566 µs per frame on average, about the same as `short`.
- Landing: smoothie.nvim ends where the native command ends in all 52 scenarios, 5 runs each; vim-smoothie in 51 (`wrap/5xC-D`, five `<C-D>` 10 ms apart, missed in all 5 runs).

## License

MIT, see [LICENSE](LICENSE).

smoothie.nvim reimplements the features and the Vimscript interface of [vim-smoothie](https://github.com/psliwka/vim-smoothie) by Piotr Śliwka (MIT). It shares no code with it.
