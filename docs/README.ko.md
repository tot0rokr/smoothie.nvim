# smoothie.nvim

Neovim용 smooth scrolling plugin이다. [vim-smoothie](https://github.com/psliwka/vim-smoothie)를 Lua로 다시 구현했고, screen row 단위로 움직이며, native command와 같은 곳에 land하고, 입력과 다른 plugin을 방해하지 않는다.

[English README](../README.md)

- scroll command는 key를 누를 때 native로 한 번 실행된다. 그다음 화면에 보이던 view에서 그 결과까지 view와 cursor를 animate하므로, jumplist, mark, register, search 상태, `'scroll'`, message가 plugin이 없을 때와 같다.
- 거리는 screen row로 잰다. closed fold, wrap된 줄, virtual line, diff filler도 고르게 움직인다.
- motion은 `duration` 안에 끝나고, ease-out 곡선 5종 중 하나를 따른다. 첫 frame은 key의 callback 안에서 그린다.
- animation 중 누른 key는 animation을 land시킨 뒤 최종 상태에 작용한다. 같은 scroll key를 다시 누르면 속도를 이어받는다.
- `quiet` 모드를 켜면 `WinScrolled`, `CursorMoved`가 motion마다 한 번만 발생한다. 이 event에 반응하는 plugin을 위한 option이다.
- vim-smoothie를 바로 대체한다. `g:smoothie_*` option, `smoothie#do()`, `<Plug>` mapping이 그대로 동작한다.
- Neovim 0.10 이상, 의존성 없음. Vim은 지원하지 않는다.

## vim-smoothie와 비교

| 항목                                | vim-smoothie           | smoothie.nvim     |
| ----------------------------------- | ---------------------- | ----------------- |
| closed fold 위 scroll               | animate하지 않고 점프  | animate           |
| native와 같은 곳에 land한 scenario  | 51/52                  | 52/52             |
| key부터 첫 화면 변화까지            | 20.5-22.1 ms           | 1.3 ms 이하       |
| frame 하나를 그리는 CPU (33개 평균) | 1014 µs                | 667 µs (52% 빠름) |
| scroll 중 반대 방향으로 튐 (jitter) | 1회 (`wrapss/C-U@end`) | 없음              |

animation 길이 설정에 거의 영향받지 않는 항목만 적었다. animation 시간, frame 수, command 한 번의 CPU 합은 animation을 얼마나 길게 잡느냐에 따라 달라지므로 비교하지 않는다. 자세한 조건은 [측정 결과](#측정-결과)에 있다.

나아진 이유:

- **screen row 해상도.** vim-smoothie는 거리를 buffer 줄 수로 세고 화면 행 단위로 움직이는 `N<C-E>`, `Nj`로 옮긴다. 그래서 closed fold 위에서는 계획보다 멀리 가서 target으로 점프하고, wrap된 줄에서는 한 줄(여러 행)씩 끊겨 움직인다. smoothie.nvim는 `nvim_win_text_height()`로 행을 재고 같은 단위로 움직인다. `'smoothscroll'`을 켜면 긴 wrap 줄 안에서도 한 행씩 움직인다.
- **정확한 착지.** 이어 누른 key는 복원한 view가 아니라 land한 native 상태에서 target을 구하고, target에는 Neovim이 redraw할 때 하는 view 보정까지 들어간다. `winrestview()`로 재현되지 않는 target은 command를 다시 실행해 land한다.
- **정해진 시간.** vim-smoothie는 남은 거리가 줄수록 느려져 target 근처에서 오래 끈다. smoothie.nvim는 모든 motion을 `duration` 안에 끝내고, 먼 jump는 `max_travel`(window 높이 단위)만큼만 animate하며, 곡선을 고를 수 있다.
- **가벼운 frame.** Lua에서 frame마다 `<C-E>`/`<C-Y>` 한 번으로 움직이고, timer는 반올림한 위치가 바뀌는 시점에만 깨어나며, idle일 때는 아무것도 걸어 두지 않는다.
- **충돌 없음.** animation 중 다른 plugin이 view나 layout을 바꾸면 한 번 land하고 끝낸다. 움직이는 target을 쫓지 않는다. macro, `:normal`, `feedkeys()`는 즉시, 동기로 실행한다.

## 요구 사항

- Neovim 0.10 이상. test suite는 0.10.4, 0.11.4, 0.12.5에서 돌린다.
- `quiet`는 `'eventignorewin'`(Neovim 0.11)이 필요하다. 0.10에서는 `false`처럼 동작한다.
- 0.12에서는 `nvim_win_text_height()`의 `max_height`로 먼 거리 측정을 `max_travel`에서 멈춘다. 0.10과 0.11에서는 끝까지 재고, 4000줄 넘게 떨어진 jump는 먼 jump로 처리한다.

## 설치

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  'tot0rokr/smoothie.nvim',
  main = 'smoothie',
  lazy = false,
  opts = {},
}
```

`opts`나 `config`로 설정하고 `keys`는 쓰지 않는다. lazy.nvim의 `keys` handler는 첫 key를 typed가 아닌 입력으로 다시 넣으므로 그 key는 animate하지 않는다. lazy-loading은 필요 없다. startup에서는 mapping만 만들고 animation engine은 첫 scroll에서 load한다.

[vim-plug](https://github.com/junegunn/vim-plug):

```vim
Plug 'tot0rokr/smoothie.nvim'
```

내장 package:

```sh
git clone https://github.com/tot0rokr/smoothie.nvim ~/.local/share/nvim/site/pack/plugins/start/smoothie.nvim
nvim -c 'helptags ~/.local/share/nvim/site/pack/plugins/start/smoothie.nvim/doc' -c q
```

## 설정

설정하지 않으면 load할 때 기본 key 16개를 mapping한다. 바꾸려면 plugin load 전이나 후에 `setup()`을 호출한다.

```lua
require('smoothie').setup({
  duration = 300,
  jumps = true,
  quiet = true,
})
```

`setup()`은 호출할 때마다 이전 호출이 아니라 기본값 위에 option을 적용하고, 이전 호출이 만든 mapping을 바꾼다. 모르는 option이나 잘못된 type은 error를 낸다.

| Option              | Type             | Default                    | 설명                                             |
| ------------------- | ---------------- | -------------------------- | ------------------------------------------------ |
| `enabled`           | boolean          | `true`                     | 전체 on/off                                      |
| `keys`              | `string[]`       | `default_keys`             | mapping할 key (`<>` notation). `{}`이면 없음     |
| `jumps`             | boolean          | `false`                    | `gg`, `G`도 mapping                              |
| `search`            | boolean          | `false`                    | `n` `N` `*` `#` `g*` `g#`도 mapping              |
| `mouse`             | boolean          | `false`                    | `<ScrollWheelDown>`, `<ScrollWheelUp>`도 mapping |
| `duration`          | number, ms       | `400`                      | window 높이 이상 움직이는 motion의 시간          |
| `easing`            | string or 1-5    | `'cubic'`                  | ease-out 곡선                                    |
| `fps`               | number 1-240     | `60`                       | frame rate 상한                                  |
| `max_travel`        | number > 0       | `2`                        | animate하는 최대 거리 (window 높이 단위)         |
| `quiet`             | boolean          | `false`                    | `WinScrolled`, `CursorMoved`를 motion마다 한 번  |
| `max_filesize`      | bytes or `false` | `false`                    | 이보다 큰 buffer는 즉시 scroll                   |
| `exclude_binary`    | boolean          | `true`                     | binary buffer는 즉시 scroll                      |
| `exclude_filetypes` | `string[]`       | `{}`                       | 즉시 scroll하는 filetype                         |
| `exclude_buftypes`  | `string[]`       | `{ 'terminal', 'prompt' }` | 즉시 scroll하는 buftype                          |

- 기본 `keys`는 `<C-D>` `<C-U>` `<C-F>` `<C-B>` `<PageDown>` `<PageUp>` `<S-Down>` `<S-Up>` `z+` `z^` `zt` `z<CR>` `z.` `zz` `z-` `zb`이다.
- window 높이보다 짧은 `r`행 motion은 `duration * sqrt(r / height)`만큼 걸린다.
- `mouse`는 pointer 아래 window를 scroll하고, 이어지는 wheel 입력은 누적된다.
- `max_travel`보다 먼 jump는 시작할 때 한 번 끊고 마지막 `max_travel`만큼만 animate한다.
- `max_filesize`는 buffer의 byte 크기와 비교하므로 저장하지 않은 buffer나 생성된 buffer에도 적용된다. `max_filesize = 2 * 1024 * 1024`이면 2 MiB가 넘는 파일은 즉시 scroll한다.
- `'binary'`가 켜져 있거나 파일 앞 8 KiB에 NUL byte가 있으면 binary buffer로 본다. git이 쓰는 판별 방식이다. 파일은 buffer마다 한 번만 읽고 결과를 `b:smoothie_binary`에 기억한다. 이 변수를 직접 설정하면 판별을 덮어쓴다.
- key는 Normal, Visual mode에만 mapping한다. `d<C-D>`와 Select mode 입력은 native와 같다. 이미 다른 mapping이 있는 key는 건너뛰고 `:checkhealth smoothie`가 보여준다.

### easing

모든 곡선은 `1 - (1 - t)^n` 꼴이고 `n`만 다르다. `n`이 클수록 빠르게 출발하고 마지막 행에 오래 머문다. 1행 미만의 움직임은 화면에 보이지 않으므로 체감은 더 빠르다.

| `easing`       | 출발 속도 (평균 대비) | 느낌                               |
| -------------- | --------------------- | ---------------------------------- |
| `linear`       | 1배                   | 같은 속도로 가다가 멈춘다          |
| `quadratic`    | 2배                   | 끝까지 고르게 감속한다             |
| `cubic` (기본) | 3배                   | 빠르게 출발하고 끝을 짧게 늦춘다   |
| `quartic`      | 4배                   | 대부분을 처음 몇 frame에 간다      |
| `quintic`      | 5배                   | 거의 점프처럼 도착하고 끝을 늦춘다 |

### quiet 모드

`quiet = true`이면 animation 중인 window가 `WinScrolled`를 무시하고, animation이 cursor를 움직이면 `CursorMoved`도 무시한다. motion이 끝나면 native scroll 한 번처럼 `WinScrolled`는 motion 전체의 변화를 `v:event`에 담아 한 번, `CursorMoved`는 cursor가 움직였으면 한 번 발생한다. 이어 누른 key로 이어진 motion도 한 번이다.

이 event에 무거운 handler를 걸거나 update를 throttle하는 plugin이 있으면 켠다. 예를 들어 render-markdown.nvim은 이어지는 event 중 첫 event에서만 다시 그리므로, frame마다 event를 받으면 끝난 view의 일부를 그리지 않은 채 남긴다. 대가로 scrollbar, context header 같은 plugin은 animation이 끝날 때까지 motion 전 상태를 보여준다. Neovim 0.11이 필요하고, 0.10에서는 `false`처럼 동작하며 `:checkhealth smoothie`가 경고한다.

render-markdown.nvim, coc.nvim, context.vim, indent-blankline.nvim, vim-airline, vim-gitgutter를 켠 config, NVIM 0.12.5, 120x50, `'scrolloff'` 9, 기본 `duration`에서 쟀다.

- 모든 줄이 heading인 5000줄 markdown에서 `<C-F>`: `quiet` 없이는 land하고 100 ms 뒤에 화면 48줄 중 23-30줄만 render돼 있었다 (34회 중 29회, 그중 3회는 600 ms 뒤에도). `quiet`를 켜면 34회 모두 48줄이 render돼 있었다. 0.11.4에서도 같다.
- scroll 한 번의 event: `quiet` 없이는 `WinScrolled`와 `CursorMoved`가 3-17번씩, 켜면 한 번씩.
- 7828줄 C 파일에서 `<C-D>`/`<C-U>`: frame 수는 같고, animation 한 번의 Neovim CPU가 13-16% 줄었다. child process(coc.nvim의 node, python host) CPU는 절반 이하로 줄었다.
- 표와 code block이 있는 384줄 markdown 파일에서 `<C-D>`/`<C-U>`: `quiet` 없이는 event handler가 animation 중 view를 옮겨 약 75 ms 만에 land했다. `quiet`를 켜면 끝까지 animate해 약 240 ms 걸렸고, frame이 늘어 animation 한 번의 CPU가 55-69% 늘었다.

## 명령과 API

- `:Smoothie [enable|disable|toggle]`: plugin을 켜고 끈다. 기본은 `toggle`이다. mapping은 그대로 두고, 꺼진 동안 즉시 scroll한다.
- `:checkhealth smoothie`: 사용 중인 Neovim 기능, 꺼진 이유, 설정, 건너뛴 key, 무시하는 vim-smoothie global, engine 상태를 보여준다.

모두 `require('smoothie')`에 있다.

| Function                            | 설명                                                           |
| ----------------------------------- | -------------------------------------------------------------- |
| `scroll(keys, opts?)`               | `keys`를 native로 실행하고 변화를 animate한다. 시작하면 `true` |
| `stop()`                            | 모든 animation을 target에 정확히 land한다                      |
| `is_animating(win?)`                | `nil`이면 아무 window, `0`이면 현재 window                     |
| `enable()`, `disable()`, `toggle()` | `enabled` option을 바꾼다                                      |
| `enabled(win?)`                     | `win`에서 켜져 있는지 (기본: 현재 window)                      |
| `default_keys`                      | 기본 key 16개                                                  |
| `skipped`                           | 건너뛴 key의 `"<mode> <lhs>"` list                             |

`scroll()`은 `<>` notation을 받는다. `'<C-d>zz'`처럼 command를 이어 쓰면 motion 하나로 animate한다. `opts.count`는 0보다 크면 앞에 붙고 기본값은 `vim.v.count`다. `opts.win`은 focus를 옮기지 않고 다른 window를 scroll한다.

```lua
vim.keymap.set({ 'n', 'x' }, '<Leader>d', function() require('smoothie').scroll('<C-d>zz') end)
```

`<Plug>` mapping은 Normal, Visual mode에 있다: `<Plug>(SmoothieDownwards)`(`<C-D>`), `<Plug>(SmoothieUpwards)`(`<C-U>`), `<Plug>(SmoothieForwards)`(`<C-F>`), `<Plug>(SmoothieBackwards)`(`<C-B>`), `<Plug>(Smoothie_gg)`, `<Plug>(Smoothie_G)`. mapping의 rhs 전체로 쓰면 animate하고 count도 전달된다.

## 끄기

command마다 다음 순서로 확인하고, 먼저 해당하는 조건에서 command를 native로 즉시 실행한다.

1. `g:neovide`나 `g:started_by_firenvim`이 `0`이나 `v:false`가 아닌 값이다. Neovide는 scroll을 직접 animate하고 firenvim은 redraw가 느리다.
2. `g:smoothie_enabled`가 `0` 또는 `v:false`다.
3. `enabled` option이 `false`다.
4. `w:smoothie_enabled` 또는 `b:smoothie_enabled`가 `0` 또는 `v:false`다.
5. buffer의 `'buftype'`이나 `'filetype'`이 제외 목록에 있다.
6. buffer가 `max_filesize`보다 크다.
7. `exclude_binary`가 켜져 있고 buffer가 binary다.

macro, `:normal`, `t` flag 없는 `feedkeys()`, mapping rhs의 끝에 있는 key, `'scrollbind'`나 `'cursorbind'`가 켜진 window, `'foldopen'`에 `all`이 있을 때, `'foldenable'` window에서 `'foldclose'`가 `all`일 때, 가로 scroll이 생길 수 있는 `'nowrap'` window도 즉시 실행한다.

## vim-smoothie에서 옮기기

`setup()`을 호출하기 전까지는 startup에 아래 global을 한 번 읽는다. `setup()`을 호출하면 그 값으로 바뀐다.

| Global                             | 처리                                    |
| ---------------------------------- | --------------------------------------- |
| `g:smoothie_enabled`               | command마다 읽는다                      |
| `g:smoothie_remapped_commands`     | `keys`로 쓴다. 아래 두 flag는 무시한다  |
| `g:smoothie_no_default_mappings`   | `keys = {}`, `jumps = false`            |
| `g:smoothie_experimental_mappings` | `jumps = true`                          |
| `g:smoothie_update_interval`       | 무시. `fps`를 쓴다                      |
| `g:smoothie_speed_*`               | 무시. `duration`, `easing`을 쓴다       |
| `g:smoothie_redraw_at_finish`      | 무시. 끝에 `:mode`로 다시 그리지 않는다 |

- `smoothie#do("\<C-D>")`는 raw key를 받고 `v:count`를 앞에 붙인다. `smoothie#downwards()`, `#upwards()`, `#forwards()`, `#backwards()`도 있다. Vimscript 함수로 부른 search key는 `v:hlsearch`를 잃으므로(`:help function-search-undo`) search key는 `search = true`나 `scroll()`로 쓴다.
- vim-smoothie에서 사라진 `<Plug>(Smoothie_gg)`, `<Plug>(Smoothie_G)`를 되살렸다.
- 고친 vim-smoothie issue: fold 위에서 멈추거나 점프 (#40, #20, #34), context.vim, render-markdown.nvim과 끝없이 떨림 (#45, #53), buffer 끝에서 첫 scroll이 끊김 (#47), mapping에서 scroll 뒤 `zz` (#46), vim-libmodal 같은 `getchar()` loop (#42), 느린 UI와 firenvim (#17, #19), 길게 늘어지는 끝과 속도 설정 부재 (#22, #27), search motion (#33, #37), mouse wheel (#44), buffer별 끄기 (#51), 사라진 `<Plug>` mapping (#43).

## 알려진 제약

- `'scrolloff'`가 window 높이의 절반 이상이면 animation 중 이어 누른 key가 몇 행 다르게 land할 수 있다. key 하나는 정확히 land한다.
- animation 중 window 크기가 바뀌면, Neovim이 이전 resize에서 저장한 row 비율을 다시 쓰는 경우 몇 행 다르게 land할 수 있다.
- rhs가 count로 시작하는 mapping(`nmap X 5<C-D>`)은 즉시 scroll한다. `scroll('5<C-d>')`나 `<Plug>` mapping을 쓴다.
- `scroll()`과 `smoothie#do()`는 `:normal!`처럼 key를 실행하므로 실패한 command가 macro를 끝내지 않는다. mapped key는 Neovim처럼 끝낸다.
- `quiet`에서는 animation을 land시킨 key의 event가 animation의 event와 합쳐지고, 일부 script나 `noautocmd` 경우에 event가 사라지거나 억제가 남는다.
- Insert mode의 `<PageUp>`/`<PageDown>`은 animate하지 않는다.

전체 목록과 이유는 `:help smoothie-limitations`에 있다.

## 개발

test (한 번에 약 4-5분):

```sh
nvim --headless --clean -c "luafile tests/run.lua"
```

- test마다 `ok`, `FAIL`, `RESIDUAL` 중 하나와 id, 이름을 출력하고, 끝에 summary를 출력한다. `FAIL`이 하나라도 있으면 exit code는 1이다. `RESIDUAL`은 문서화한 제약을 재현하는 test라 suite를 실패시키지 않는다.
- 모든 test는 native reference run과 비교한다. 같은 입력과 timing으로 plugin mapping만 뺀 run이다.
- 다른 `nvim` binary로 시작하면 그 version을 test한다. child process도 같은 binary를 쓴다.
- 결과: 0.12.5와 0.11.4는 134 ok, 0 FAIL, 5 RESIDUAL, 0.10.4는 117 ok, 0 FAIL, 5 RESIDUAL이다. `quiet` test는 0.11 이상에서만 등록한다.

| Variable                      | 뜻                                                 |
| ----------------------------- | -------------------------------------------------- |
| `SMOOTHIE_TEST=<lua pattern>` | `"<id> <name>"`이 match하는 test만 실행한다        |
| `SMOOTHIE_TEST_FULL=1`        | 착지 matrix를 넓힌다 (`scrolloff=999`, 파일 맨 위) |
| `SMOOTHIE_TEST_RTP=<dir>`     | test할 plugin root (기본: 이 저장소)               |
| `SMOOTHIE_TEST_VERBOSE=1`     | case가 여럿인 test의 실패 case를 모두 출력한다     |

vim-smoothie 대비 benchmark (빈 `OUT`에서 약 26분, 기준 결과를 다시 쓰면 약 12분):

```sh
git clone https://github.com/psliwka/vim-smoothie /tmp/vim-smoothie
UPSTREAM=/tmp/vim-smoothie OUT=/tmp/smoothie.nvim-bench bench/run.sh
```

native와 vim-smoothie 기준 결과를 `$OUT/upstream`에 만든 뒤 smoothie.nvim를 재고, 비교 파일 5개(`cmp-*.txt`)를 `$OUT`에 만든다. scenario 하나를 frame 단위로 보려면 `nvim --headless --clean -l bench/show.lua "$OUT/smoothie.nvim.json" 'wrapss/C-U@end'`를 실행한다.

### 측정 결과

2026-09-30에 `bench/run.sh`로 쟀다. AMD EPYC-Genoa 16 CPU, Linux 6.8, NVIM 0.12.5, `nvim --headless --clean`, 120x50 (window 높이 48), matchparen 켬, scenario마다 5회 median. vim-smoothie `df1e324`(2022-06-10)는 기본 설정, smoothie.nvim는 `duration = 200`, `easing = 'cubic'`, `fps = 60`이다. buffer 4개(`short`: 10000줄, `wrap`: 5000줄에 세 줄마다 300자, `wrapss`: 같은 text에 `'smoothscroll'`, `folds`: closed marker fold가 있는 10000줄)에 command 13개씩, 모두 52개 scenario다.

frame 하나를 그리는 CPU는 연속한 두 frame 사이 CPU의 median에서 harness의 idle 비용을 뺀 값이고, Neovim의 redraw와 autocmd를 포함한다.

| buffer          | vim-smoothie | smoothie.nvim | 속도 증가 |
| --------------- | ------------ | ------------- | --------- |
| `short` (11개)  | 870 µs       | 546 µs        | 59%       |
| `wrap` (11개)   | 934 µs       | 651 µs        | 43%       |
| `wrapss` (11개) | 1238 µs      | 804 µs        | 54%       |
| 평균 (33개)     | 1014 µs      | 667 µs        | 52%       |

- 두 plugin이 모두 animate한 scenario만 넣었다. 속도 증가는 (vim-smoothie − smoothie.nvim) / smoothie.nvim다. `gg`, `G`는 두 plugin 모두 기본으로 mapping하지 않아 native로 실행되므로 빠진다.
- `folds`는 뺐다. vim-smoothie는 closed fold 위에서 animate하지 않고 1-4 frame 만에 target으로 점프한다. smoothie.nvim는 같은 scenario를 frame당 평균 566 µs로 animate하고, 이는 `short`와 비슷하다.
- 착지: smoothie.nvim는 52개 scenario 모두 5회 모두 native와 같은 곳에서 끝난다. vim-smoothie는 51개다 (`wrap/5xC-D`, 10 ms 간격으로 `<C-D>` 5번은 5회 모두 어긋남).

## License

MIT. [LICENSE](../LICENSE)를 참고한다.

smoothie.nvim는 Piotr Śliwka의 [vim-smoothie](https://github.com/psliwka/vim-smoothie)(MIT)의 기능과 Vimscript interface를 다시 구현했다. vim-smoothie의 코드는 쓰지 않았다.
