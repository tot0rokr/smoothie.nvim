#!/usr/bin/env bash
# Usage: UPSTREAM=<vim-smoothie checkout> [OUT=<result dir>] bench/run.sh
# OUT defaults to ${TMPDIR:-/tmp}/smoothie.nvim-bench. Native and vim-smoothie
# baselines go to $OUT/upstream; a baseline whose JSON already exists is reused.
set -eu

B=$(cd "$(dirname "$0")" && pwd)
P=$(dirname "$B")
UPSTREAM=$(cd "${UPSTREAM:?set UPSTREAM to a vim-smoothie checkout}" && pwd)
[ -f "$UPSTREAM/plugin/smoothie.vim" ] || { echo "not a vim-smoothie checkout: $UPSTREAM" >&2; exit 1; }
OUT=${OUT:-${TMPDIR:-/tmp}/smoothie.nvim-bench}
U=$OUT/upstream
mkdir -p "$U"

# run headless|ui RESULT.json [VAR=value ...]; the log goes next to RESULT.json
run() {
  local mode=$1 out=$2
  shift 2
  echo "=== $out"
  if [ "$mode" = ui ]; then
    env "$@" BENCH_OUT="$out" timeout 3600 nvim --headless --clean -l "$B/bench_ui.lua" > "${out%.json}.log" 2>&1
  else
    env "$@" BENCH_OUT="$out" timeout 3600 nvim --headless --clean -c "luafile $B/bench.lua" > "${out%.json}.log" 2>&1
  fi
}
baseline() { [ -f "$2" ] || run "$@"; }

EXP='vim.g.smoothie_experimental_mappings = 1'
baseline headless "$U/smoothie-default.json" BENCH_LABEL=smoothie-default BENCH_RUNS=5 BENCH_PLUGIN="$UPSTREAM"
baseline headless "$U/smoothie-experimental.json" BENCH_LABEL=smoothie-experimental BENCH_RUNS=5 \
  BENCH_PLUGIN="$UPSTREAM" BENCH_PRE="$EXP"
baseline headless "$U/smoothie-default-nomatchparen.json" BENCH_LABEL=smoothie-default-nomatchparen BENCH_RUNS=5 \
  BENCH_PLUGIN="$UPSTREAM" BENCH_MATCHPAREN=0 BENCH_SCENARIOS='^short/,^folds/'
baseline ui "$U/ui-native.json" BENCH_LABEL=native BENCH_RUNS=3 BENCH_PLUGIN=none
baseline ui "$U/ui-smoothie-default.json" BENCH_LABEL=smoothie-default BENCH_RUNS=3 BENCH_PLUGIN="$UPSTREAM"
baseline ui "$U/ui-smoothie-experimental.json" BENCH_LABEL=smoothie-experimental BENCH_RUNS=3 \
  BENCH_PLUGIN="$UPSTREAM" BENCH_PRE="$EXP"

NS=(BENCH_PLUGIN="$P" BENCH_BUSY='require("smoothie").is_animating()' BENCH_ABORT='require("smoothie").stop()')
DEF='require("smoothie").setup({})'
JUMPS='require("smoothie").setup({jumps=true})'
run headless "$OUT/smoothie.nvim.json" "${NS[@]}" BENCH_LABEL=smoothie.nvim BENCH_RUNS=5 BENCH_POST="$DEF"
run headless "$OUT/smoothie.nvim-jumps.json" "${NS[@]}" BENCH_LABEL=smoothie.nvim-jumps BENCH_RUNS=5 \
  BENCH_POST="$JUMPS"
run headless "$OUT/smoothie.nvim-nomp.json" "${NS[@]}" BENCH_LABEL=smoothie.nvim-nomp BENCH_RUNS=5 \
  BENCH_MATCHPAREN=0 BENCH_POST="$DEF"
run ui "$OUT/ui-smoothie.nvim.json" "${NS[@]}" BENCH_LABEL=ui-smoothie.nvim BENCH_RUNS=3 BENCH_POST="$DEF"
run ui "$OUT/ui-smoothie.nvim-jumps.json" "${NS[@]}" BENCH_LABEL=ui-smoothie.nvim-jumps BENCH_RUNS=3 \
  BENCH_POST="$JUMPS"

C=(nvim --headless --clean -l "$B/compare.lua")
"${C[@]}" "$U/smoothie-default.json" "$OUT/smoothie.nvim.json" > "$OUT/cmp-default.txt"
"${C[@]}" "$U/smoothie-experimental.json" "$OUT/smoothie.nvim-jumps.json" > "$OUT/cmp-jumps.txt"
"${C[@]}" "$U/smoothie-default-nomatchparen.json" "$OUT/smoothie.nvim-nomp.json" > "$OUT/cmp-nomp.txt"
COMPARE_FIELDS=ui "${C[@]}" "$U/ui-native.json" "$U/ui-smoothie-default.json" "$OUT/ui-smoothie.nvim.json" \
  > "$OUT/cmp-ui.txt"
COMPARE_FIELDS=ui "${C[@]}" "$U/ui-native.json" "$U/ui-smoothie-experimental.json" \
  "$OUT/ui-smoothie.nvim-jumps.json" > "$OUT/cmp-ui-jumps.txt"

echo "compare outputs:"
printf '  %s\n' "$OUT"/cmp-{default,jumps,nomp,ui,ui-jumps}.txt
