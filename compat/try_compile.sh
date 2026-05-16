#!/bin/bash
# Phase 1 smoke test: compile each solver's math sources as headless objects.
# Lists are per-solver (they diverge in what exists on disk).

set -o pipefail
cd "$(dirname "$0")/.."

FLAGS=(-std=c++17 -DFEMM_HEADLESS
       -Wno-deprecated-declarations
       -Wno-nonportable-include-path
       -Wno-format
       -Wno-null-conversion
       -Icompat)

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

fail=0
try() {
  local solver=$1; shift
  for src in "$@"; do
    local path="$solver/$src"
    if [[ ! -f "$path" ]]; then
      echo "MISSING $path"; continue
    fi
    local out="$TMPDIR/${solver}_$(basename "$src").o"
    if clang++ "${FLAGS[@]}" -I"$solver" -c "$path" -o "$out" 2> "$TMPDIR/err"; then
      printf 'OK    %s\n' "$path"
    else
      printf 'FAIL  %s\n' "$path"
      grep -E 'error:|fatal' "$TMPDIR/err" | head -5 | sed 's/^/      /'
      fail=1
    fi
  done
}

try belasolv spars.cpp cuthill.cpp prob1big.cpp femmedoccore.cpp
try csolv    cspars.cpp complex.cpp CUTHILL.CPP PROB1BIG.CPP femmedoccore.cpp
try hsolv    complex.cpp SPARS.CPP CUTHILL.CPP prob1big.cpp hsolvdoc.cpp
try fkn      complex.cpp spars.cpp cspars.cpp cuthill.cpp matprop.cpp \
             fullmatrix.cpp prob1big.cpp prob2big.cpp prob3big.cpp \
             prob4big.cpp femmedoccore.cpp

exit $fail
