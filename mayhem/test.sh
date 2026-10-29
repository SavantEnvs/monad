#!/usr/bin/env bash
#
# mayhem/test.sh — run monad's pure gtest binaries (built by mayhem/build.sh with normal flags) and
# parse their gtest summaries. A binary that prints no summary (e.g. neutered) counts as a failure.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

TESTS=(compact_encode_test nibbles_view_test big_endian_serialization_test
       unsigned_20_test encode_branch_test encode_two_pieces_test)

passed=0 failed=0 skipped=0
for t in "${TESTS[@]}"; do
  bin="build/test/category/mpt/test/$t"
  if [ ! -x "$bin" ]; then
    echo "missing test binary $bin (mayhem/build.sh should have built it)" >&2
    failed=$((failed + 1)); continue
  fi
  out="$("$bin" 2>&1)"; rc=$?
  printf '%s\n' "$out" | tail -n 8
  ran="$(printf '%s\n' "$out" | sed -n 's/^\[==========\] \([0-9]\+\) tests\? from .* ran\..*/\1/p' | tail -n1)"
  p="$(printf '%s\n' "$out" | sed -n 's/^\[  PASSED  \] \([0-9]\+\) tests\?\..*/\1/p' | tail -n1)"
  s="$(printf '%s\n' "$out" | sed -n 's/^\[  SKIPPED \] \([0-9]\+\) tests\?, listed below.*/\1/p' | tail -n1)"
  if [ -z "$ran" ] || [ -z "$p" ] || [ "$ran" -eq 0 ]; then
    echo "$t: no gtest summary (rc=$rc)" >&2
    failed=$((failed + 1)); continue
  fi
  s="${s:-0}"
  f=$(( ran - p - s ))
  [ "$f" -ge 0 ] || f=0
  [ "$rc" -eq 0 ] || [ "$f" -gt 0 ] || f=1
  passed=$((passed + p)); skipped=$((skipped + s)); failed=$((failed + f))
done

emit_ctrf "gtest" "$passed" "$failed" "$skipped"
