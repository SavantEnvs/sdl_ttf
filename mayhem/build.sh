#!/usr/bin/env bash
#
# mayhem/build.sh — build the backport target sdl-ttf-fuzzer-buggy-mhh-run-26: the mayhemheroes
# fuzz_open_font_from_mem.c harness (ported to the SDL3_ttf API upstream now targets), its
# standalone reproducer, and the functional oracle.
#
# This is a DIFFERENT harness from the live mayhem branch's fuzz_ttf_render.c. The mayhemheroes
# run this backport reproduces drove SDL_ttf through TTF_RenderText_Solid(), and its bugs live in
# the text-LAYOUT path (CollectGlyphs / CollectGlyphsWithFallbacks / GetCachedGlyphPositions in
# src/SDL_ttf.c) — code that only runs when HarfBuzz-based shaping is compiled in. The live target
# builds with -DSDLTTF_HARFBUZZ=OFF (a deliberate scope decision, see its build.sh), so it cannot
# reach this code at all: the input-interface caveat (docs/backport-worker-prompt.md) applies, and
# the original harness had to be reconstructed rather than reused. This build therefore turns
# HarfBuzz ON against the SYSTEM libharfbuzz-dev/libfreetype-dev/libsdl3-dev — matching the
# original mayhemheroes build, not the live target's vendored+instrumented FreeType.
#
# Sanitizer flags are used AS-IS from the base image (no -fno-sanitize= relaxations): one of the
# bugs this target reproduces is a genuine shift-base UB in CollectGlyphs, so nothing here may
# suppress it.
#
# Produces:
#   /mayhem/fuzz_open_font_from_mem              libFuzzer target
#   /mayhem/fuzz_open_font_from_mem-standalone   run-once reproducer (no libFuzzer runtime)
#   /mayhem/build-oracle/kat_probe               clean KAT binary for mayhem/test.sh
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "${SRC:=/mayhem}"

CMAKE_COMMON=(
    -DCMAKE_C_COMPILER="$CC"
    -DBUILD_SHARED_LIBS=OFF
    -DSDLTTF_VENDORED=OFF
    -DSDLTTF_HARFBUZZ=ON
    -DSDLTTF_PLUTOSVG=OFF
    -DSDLTTF_SAMPLES=OFF
)

# ---------------------------------------------------------------------------------------------
# 1) libFuzzer target: SDL_ttf built with $SANITIZER_FLAGS + $DEBUG_FLAGS + fuzzer-no-link
#    coverage instrumentation, against the system FreeType/HarfBuzz.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link"

rm -rf build-fuzz
# shellcheck disable=SC2086
cmake -B build-fuzz -G Ninja \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    "${CMAKE_COMMON[@]}" \
    -DCMAKE_C_FLAGS="$FUZZ_CFLAGS"
cmake --build build-fuzz -j"$MAYHEM_JOBS" --target SDL3_ttf-static

SDL3_CFLAGS="$(pkg-config --cflags sdl3)"
SDL3_LIBS="$(pkg-config --libs sdl3)"
DEP_LIBS="$(pkg-config --libs freetype2 harfbuzz)"
HARNESS="mayhem/fuzz_open_font_from_mem.c"
INCLUDES="-Iinclude $SDL3_CFLAGS"

# shellcheck disable=SC2086
$CC $FUZZ_CFLAGS $LIB_FUZZING_ENGINE \
    "$HARNESS" $INCLUDES \
    build-fuzz/libSDL3_ttf.a $SDL3_LIBS $DEP_LIBS -lm \
    -o /mayhem/fuzz_open_font_from_mem

# 2) Standalone run-once reproducer (no libFuzzer runtime): same harness + same sanitized lib,
#    linked against the base image's $STANDALONE_FUZZ_MAIN driver instead.
# shellcheck disable=SC2086
$CC $FUZZ_CFLAGS \
    "$STANDALONE_FUZZ_MAIN" "$HARNESS" $INCLUDES \
    build-fuzz/libSDL3_ttf.a $SDL3_LIBS $DEP_LIBS -lm \
    -o /mayhem/fuzz_open_font_from_mem-standalone

# ---------------------------------------------------------------------------------------------
# 3) Clean oracle build (NO sanitizers) so mayhem/test.sh stays an honest functional oracle,
#    independent of the fuzz build above. $COVERAGE_FLAGS is empty unless a coverage build
#    requests it.
rm -rf build-oracle
# shellcheck disable=SC2086
cmake -B build-oracle -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    "${CMAKE_COMMON[@]}" \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS"
cmake --build build-oracle -j"$MAYHEM_JOBS" --target SDL3_ttf-static

# shellcheck disable=SC2086
$CC -O2 $COVERAGE_FLAGS -Iinclude $SDL3_CFLAGS \
    mayhem/kat_probe.c build-oracle/libSDL3_ttf.a $SDL3_LIBS $DEP_LIBS -lm \
    -o build-oracle/kat_probe

file build-oracle/kat_probe | grep -q 'dynamically linked' || {
    echo "build.sh: build-oracle/kat_probe is not dynamically linked — the sabotage oracle" >&2
    echo "          check needs a dynamically-linked binary to intercept." >&2
    exit 1
}

echo "build.sh: built /mayhem/fuzz_open_font_from_mem (+ -standalone) and build-oracle/kat_probe (oracle)"
