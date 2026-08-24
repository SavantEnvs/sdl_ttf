#!/usr/bin/env bash
#
# mayhem/build.sh — build SDL_ttf's fuzz harness + standalone reproducer + the functional oracle.
#
# SDL_ttf (main branch == SDL3_ttf) renders TrueType/OpenType fonts on top of FreeType, using
# SDL3 for surfaces/IO streams. The interesting fuzz surface is FONT PARSING, which happens
# almost entirely inside FreeType, not SDL_ttf's own ~2000-line glue layer — so per PORTING.md's
# "instrument the LIBRARY, not just the harness TU", this build compiles FreeType FROM SOURCE
# (the pinned `external/freetype` git submodule, already vendored by upstream for exactly this
# purpose) with the same $SANITIZER_FLAGS as SDL_ttf itself, rather than linking the system
# libfreetype6 package (which ships with zero sanitizer/coverage instrumentation).
#
# Scope decision: harfbuzz (text shaping) and plutosvg/plutovg (OT-SVG color glyphs) are built
# OFF (-DSDLTTF_HARFBUZZ=OFF -DSDLTTF_PLUTOSVG=OFF). Rationale: (a) they are optional rendering
# refinements, not font-format PARSING — the attack surface this port targets; (b) instrumenting
# them too would roughly double the vendored dependency surface (harfbuzz alone is a large C++
# shaping engine) for comparatively little additional crash-finding value on malformed font
# bytes; (c) SDL_ttf still fully exercises FreeType's sfnt/truetype/cff/type1/cid/pcf/bdf/
# winfnt/pfr/type42 parsers and its own synth-bold/synth-italic/outline-stroke/kerning/wrap code
# either way. See mayhem/fuzz_ttf_render.c for the harness and the PR description for more.
#
# Produces:
#   /mayhem/fuzz_ttf_render              libFuzzer target (sanitized SDL_ttf + FreeType, built
#                                         from the vendored external/freetype submodule)
#   /mayhem/fuzz_ttf_render-standalone   run-once reproducer (no libFuzzer runtime)
#   /mayhem/build-oracle/kat_probe       clean (NORMAL flags, system libfreetype) KAT binary for
#                                        mayhem/test.sh
#
# Air-gapped/idempotent: the FreeType submodule is normally already checked out on disk before
# this script runs (CI's `actions/checkout` uses `submodules: recursive`). The one place that is
# NOT true is verify-repo.sh's CI-parity build, which builds from a plain `git clone` of HEAD —
# by design that has the gitlink but no submodule CONTENT (mirrors what a checkout WITHOUT
# `submodules: true` would look like). So: populate it here ourselves, but ONLY if it's actually
# missing — this needs the network exactly once, the first time content lands in an image layer.
# Every later re-run (including the offline `--network none` air-gap check, which re-runs this
# script INSIDE that same already-built image) finds the submodule already populated from that
# first build and skips straight past this step — no network needed, and safe to re-run.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the environment (base image exports the defaults); fall back for a bare run.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "${SRC:=/mayhem}"

if [ ! -f external/freetype/CMakeLists.txt ]; then
    echo "build.sh: external/freetype submodule not populated on disk — fetching it now (needed once;" >&2
    echo "          baked into the image layer after this, so later/offline re-runs skip this step)" >&2
    git submodule update --init external/freetype
fi

# ---------------------------------------------------------------------------------------------
# 1) libFuzzer target: SDL_ttf + FreeType, BOTH compiled with $SANITIZER_FLAGS + fuzzer-no-link
#    coverage instrumentation (appended UNCONDITIONALLY, including when $SANITIZER_FLAGS is
#    empty — see PORTING.md §6). Two benign UBSan false positives on legitimate, pervasive
#    idioms in this codebase are relaxed (kept ASan + the rest of UBSan halting):
#      - pointer-overflow: FreeType's ftstroke.c computes `outline->points + outline->n_points`
#        on an empty (NULL-backed) outline as part of its normal zero-point-stroke path
#        (`applying zero offset to null pointer`) — the same NULL+0 idiom PORTING.md documents
#        for xdelta.
#      - shift-base: SDL_ttf.c's F26Dot6() 26.6-fixed-point conversion left-shifts a font's
#        (occasionally legitimately negative, e.g. hanging punctuation/overshoot) ascent value
#        by 6 — standard fixed-point font math, UB by the letter of the C standard but exercised
#        on every negative-ascent glyph position, not a defect.
#    Both were confirmed to fire on ordinary, valid fonts during a local fork-mode fuzz run
#    (not just malformed input), which is what makes them "flooding/benign" rather than findings.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fno-sanitize=pointer-overflow,shift-base -fsanitize=fuzzer-no-link"

rm -rf build-fuzz
# shellcheck disable=SC2086
cmake -B build-fuzz -G Ninja \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DBUILD_SHARED_LIBS=OFF \
    -DSDLTTF_VENDORED=ON \
    -DSDLTTF_HARFBUZZ=OFF \
    -DSDLTTF_PLUTOSVG=OFF \
    -DSDLTTF_SAMPLES=OFF \
    -DCMAKE_C_FLAGS="$FUZZ_CFLAGS"
cmake --build build-fuzz -j"$MAYHEM_JOBS" --target SDL3_ttf-static

FT_INCLUDE="build-fuzz/external/freetype-build/include"
FUZZ_LIBS=(build-fuzz/libSDL3_ttf.a build-fuzz/external/freetype-build/libfreetype.a)

HARNESS="mayhem/fuzz_ttf_render.c"

# LSan hook: disable LeakSanitizer preventively (ASan's corruption checks + UBSan stay on) —
# this fleet fuzzes for memory corruption, not leaks. Build-time only, linked into every binary.
$CC -c $FUZZ_CFLAGS mayhem/lsan_off.c -o /tmp/lsan_off.o

# shellcheck disable=SC2086
$CC $FUZZ_CFLAGS $LIB_FUZZING_ENGINE \
    -Iinclude -I"$FT_INCLUDE" \
    "$HARNESS" /tmp/lsan_off.o "${FUZZ_LIBS[@]}" -lSDL3 -lm \
    -o /mayhem/fuzz_ttf_render

# 2) Standalone run-once reproducer (no libFuzzer runtime): same harness + same sanitized/
#    instrumented libs, linked against the base image's $STANDALONE_FUZZ_MAIN driver instead.
# shellcheck disable=SC2086
$CC $FUZZ_CFLAGS \
    -Iinclude -I"$FT_INCLUDE" \
    "$STANDALONE_FUZZ_MAIN" "$HARNESS" /tmp/lsan_off.o "${FUZZ_LIBS[@]}" -lSDL3 -lm \
    -o /mayhem/fuzz_ttf_render-standalone

# ---------------------------------------------------------------------------------------------
# 3) Clean oracle build (NO sanitizers, system libfreetype-dev — NOT the vendored/instrumented
#    one) so mayhem/test.sh stays an honest functional oracle that won't false-fail on benign UB,
#    and is fully independent of the fuzz build above. $COVERAGE_FLAGS is empty unless a coverage
#    build requests it.
rm -rf build-oracle
# shellcheck disable=SC2086
cmake -B build-oracle -G Ninja \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DSDLTTF_VENDORED=OFF \
    -DSDLTTF_HARFBUZZ=OFF \
    -DSDLTTF_PLUTOSVG=OFF \
    -DSDLTTF_SAMPLES=OFF \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS"
cmake --build build-oracle -j"$MAYHEM_JOBS" --target SDL3_ttf-static

# shellcheck disable=SC2086
$CC -O2 $COVERAGE_FLAGS -Iinclude \
    mayhem/kat_probe.c build-oracle/libSDL3_ttf.a -lSDL3 -lfreetype -lm \
    -o build-oracle/kat_probe

file build-oracle/kat_probe | grep -q 'dynamically linked' || {
    echo "build.sh: build-oracle/kat_probe is not dynamically linked — the sabotage oracle" >&2
    echo "          check needs a dynamically-linked binary to intercept." >&2
    exit 1
}

echo "build.sh: built /mayhem/fuzz_ttf_render (+ -standalone) and build-oracle/kat_probe (oracle)"
