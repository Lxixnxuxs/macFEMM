#!/usr/bin/env bash
# build_macos.sh — Builds the headless FEMM solvers on macOS / Linux.
#
# Produces:
#   build/belasolv/belasolve   (electrostatics)
#   build/csolv/csolve         (current flow)
#   build/hsolv/hsolve         (heat)
#   build/fkn/fknsolve         (magnetics: static 2D, axi, harmonic 2D, axi)
#   build/triangle/triangle    (Shewchuk mesher)
#   build/lua/libfemm_lua.a    (embedded Lua, used by fknsolve + libfemm_core)
#
# Usage: ./build_macos.sh
# Requires: clang++ (Xcode command-line tools), bash 3.2+, ar.

set -eu

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

FLAGS=(-std=c++17 -DFEMM_HEADLESS -O2
       -Wno-deprecated-declarations -Wno-nonportable-include-path
       -Wno-format -Wno-null-conversion -Wno-writable-strings
       -Wno-unsequenced -Wno-non-c-typedef-for-linkage)

LUA_FLAGS=("${FLAGS[@]}" -include compat/mfc_compat.h -Iliblua -Icompat)

mkdir -p build/belasolv build/csolv build/hsolv build/fkn build/triangle build/lua build/libfemm_core

# ---------- liblua (static archive) ------------------------------------------
LUA_SRCS=(
  liblua/lapi.cpp liblua/lauxlib.cpp liblua/lbaselib.cpp liblua/lcode.cpp
  liblua/ldblib.cpp liblua/ldebug.cpp liblua/ldo.cpp liblua/lfunc.cpp
  liblua/lgc.cpp liblua/liolib.cpp liblua/llex.cpp liblua/lmathlib.cpp
  liblua/lmem.cpp liblua/lobject.cpp liblua/lparser.cpp liblua/lstate.cpp
  liblua/lstring.cpp liblua/lstrlib.cpp liblua/ltable.cpp liblua/ltests.cpp
  liblua/ltm.cpp liblua/lundump.cpp liblua/lvm.cpp liblua/lzio.cpp
  liblua/COMPLEX.CPP
)

LUA_OBJS=()
for s in "${LUA_SRCS[@]}"; do
  out="build/lua/$(basename "$s" | sed 's/\.[Cc][Pp][Pp]$//').o"
  LUA_OBJS+=("$out")
  clang++ -c "${LUA_FLAGS[@]}" "$s" -o "$out"
done
rm -f build/lua/libfemm_lua.a
ar rcs build/lua/libfemm_lua.a "${LUA_OBJS[@]}"
echo "built  build/lua/libfemm_lua.a"

# ---------- belasolv --------------------------------------------------------
clang++ "${FLAGS[@]}" -Icompat -Ibelasolv \
  compat/headless_main.cpp \
  belasolv/main.cpp belasolv/spars.cpp belasolv/cuthill.cpp \
  belasolv/prob1big.cpp belasolv/femmedoccore.cpp \
  -o build/belasolv/belasolve
echo "built  build/belasolv/belasolve"

# ---------- csolv -----------------------------------------------------------
clang++ "${FLAGS[@]}" -Icompat -Icsolv \
  compat/headless_main.cpp \
  csolv/main.cpp csolv/cspars.cpp csolv/complex.cpp csolv/CUTHILL.CPP \
  csolv/PROB1BIG.CPP csolv/femmedoccore.cpp \
  -o build/csolv/csolve
echo "built  build/csolv/csolve"

# ---------- hsolv -----------------------------------------------------------
clang++ "${FLAGS[@]}" -Icompat -Ihsolv \
  compat/headless_main.cpp \
  hsolv/MAIN.CPP hsolv/SPARS.CPP hsolv/complex.cpp hsolv/CUTHILL.CPP \
  hsolv/prob1big.cpp hsolv/hsolvdoc.cpp \
  -o build/hsolv/hsolve
echo "built  build/hsolv/hsolve"

# ---------- fkn -------------------------------------------------------------
# Note: -Iliblua must come before -Ifkn so liblua/complex.h wins; fkn/complex.cpp
# is intentionally skipped (liblua/COMPLEX.CPP provides the single definition).
clang++ "${FLAGS[@]}" -Iliblua -Ifkn -Icompat \
  compat/headless_main.cpp \
  fkn/fkn_headless_globals.cpp \
  fkn/main.cpp fkn/spars.cpp fkn/cspars.cpp fkn/cuthill.cpp \
  fkn/matprop.cpp fkn/fullmatrix.cpp \
  fkn/prob1big.cpp fkn/prob2big.cpp fkn/prob3big.cpp fkn/prob4big.cpp \
  fkn/femmedoccore.cpp \
  build/lua/libfemm_lua.a \
  -o build/fkn/fknsolve
echo "built  build/fkn/fknsolve"

# ---------- triangle --------------------------------------------------------
clang -DNO_TIMER -DANSI_DECLARATORS \
      -Wno-implicit-function-declaration -Wno-deprecated-declarations -O2 \
      triangle64/triangle.c -o build/triangle/triangle -lm
echo "built  build/triangle/triangle"

# ---------- libfemm_core (static archive, Phase A) --------------------------
CORE_FLAGS=(-std=c++17 -O2 -Wall -include compat/mfc_compat.h -Iliblua -Ilibfemm_core -Icompat)
CORE_SRCS=(
  libfemm_core/femm_error.cpp
  libfemm_core/femm_doc.cpp
  libfemm_core/femm_io.cpp
  libfemm_core/femm_mesh.cpp
  libfemm_core/femm_props.cpp
  libfemm_core/femm_result.cpp
  libfemm_core/femm_lua.cpp
)
CORE_OBJS=()
for s in "${CORE_SRCS[@]}"; do
  out="build/libfemm_core/$(basename "$s" .cpp).o"
  CORE_OBJS+=("$out")
  clang++ -c "${CORE_FLAGS[@]}" "$s" -o "$out"
done
rm -f build/libfemm_core/libfemm_core.a
ar rcs build/libfemm_core/libfemm_core.a "${CORE_OBJS[@]}" "${LUA_OBJS[@]}"
echo "built  build/libfemm_core/libfemm_core.a"

# ---------- femm_cli_smoke (Phase A verification) ---------------------------
clang++ "${CORE_FLAGS[@]}" \
  libfemm_core/femm_cli_smoke.cpp \
  build/libfemm_core/libfemm_core.a \
  -o build/libfemm_core/femm_cli_smoke
echo "built  build/libfemm_core/femm_cli_smoke"

# ---------- femm_cli_integrals (Phase E verification) -----------------------
clang++ "${CORE_FLAGS[@]}" \
  libfemm_core/femm_cli_integrals.cpp \
  build/libfemm_core/libfemm_core.a \
  -o build/libfemm_core/femm_cli_integrals
echo "built  build/libfemm_core/femm_cli_integrals"

# ---------- femm_cli_regression (Windows cross-check harness) ---------------
clang++ "${CORE_FLAGS[@]}" \
  libfemm_core/femm_cli_regression.cpp \
  build/libfemm_core/libfemm_core.a \
  -o build/libfemm_core/femm_cli_regression
echo "built  build/libfemm_core/femm_cli_regression"

# ---------- femm_cli_lua (Lua compatibility smoke) -------------------------
clang++ "${CORE_FLAGS[@]}" \
  libfemm_core/femm_cli_lua.cpp \
  build/libfemm_core/libfemm_core.a \
  -o build/libfemm_core/femm_cli_lua
echo "built  build/libfemm_core/femm_cli_lua"

echo
echo "all binaries built under $ROOT/build/"
