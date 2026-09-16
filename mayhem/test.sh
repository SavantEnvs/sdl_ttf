#!/usr/bin/env bash
#
# mayhem/test.sh — functional oracle for SDL_ttf. RUNS the prebuilt clean KAT binary
# (build-oracle/kat_probe from mayhem/build.sh) against mayhem/kat/Tuffy.ttf.
#
# SDL_ttf itself ships no automated test suite (see mayhem/kat_probe.c for why); this probe is
# the project's real, memory-based TTF_OpenFontIO() API driven against real font-metrics-table
# values (not hinting/rasterization output, which is FreeType-version-sensitive) plus a real
# rendered-surface non-blank check. It is behavioral: a PATCH that neuters SDL_ttf (font loading
# always fails, rendering silently no-ops, an exit(0) short-circuit, ...) fails one or more of the
# 15 assertions below. Emits a CTRF report; exits nonzero iff any assertion failed.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "${SRC:-/mayhem}"

BIN=build-oracle/kat_probe
FONT=mayhem/kat/Tuffy.ttf

# emit_ctrf <tool> <passed> <failed> [skipped]
emit_ctrf() {
  local tool="$1" p="$2" f="$3" s="${4:-0}"
  local tests=$(( p + f + s ))
  cat > "${CTRF_REPORT:-${SRC:-/mayhem}/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": { "tests": $tests, "passed": $p, "failed": $f, "pending": 0, "skipped": $s, "other": 0 }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":0,"skipped":%d,"other":0}}}\n' \
    "$tool" "$tests" "$p" "$f" "$s"
}

if [ ! -x "$BIN" ]; then
  echo "test.sh: $BIN missing — build.sh must build it (not rebuilding here)" >&2
  emit_ctrf sdl_ttf-kat 0 1 0
  exit 1
fi
if [ ! -f "$FONT" ]; then
  echo "test.sh: $FONT missing" >&2
  emit_ctrf sdl_ttf-kat 0 1 0
  exit 1
fi

out="$("$SRC/$BIN" "$FONT" 2>&1)"
rc=$?
echo "$out"

# Every "  ok   - ..." / "  FAIL - ..." line is one assertion; the probe's own exit code
# (0 iff failed==0) is cross-checked against the counts, not trusted alone.
passed=$(printf '%s\n' "$out" | grep -c '^  ok   - ')
failed=$(printf '%s\n' "$out" | grep -c '^  FAIL - ')

if [ "$passed" -eq 0 ] && [ "$failed" -eq 0 ]; then
  echo "test.sh: kat_probe produced no recognizable ok/FAIL lines — treating as a hard failure" >&2
  failed=1
fi
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then
  # probe exited non-zero but we didn't parse a FAIL line — don't let that slip through green.
  failed=1
fi

echo "test.sh: passed=$passed failed=$failed (kat_probe rc=$rc)"
emit_ctrf sdl_ttf-kat "$passed" "$failed" 0
[ "$failed" -eq 0 ]
