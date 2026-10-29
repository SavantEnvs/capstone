#!/usr/bin/env bash
#
# mayhem/test.sh — RUN capstone's own functional suite (cstest over the YAML tests under tests/, built by
# mayhem/build.sh with normal flags) plus cstool known-answer checks. exit 0 = pass.
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


CSTEST=build-tests/cstest
CSTOOL=build-tests/cstool
[ -x "$CSTEST" ] && [ -x "$CSTOOL" ] || { echo "missing $CSTEST / $CSTOOL — mayhem/build.sh did not build them" >&2; exit 1; }

passed=0; failed=0; skipped=0

# Every YAML test case asserts the decoded asm text and details against expected values. A run that
# prints no summary (crash, or a neutered binary that exits 0 immediately) counts as a failure.
num() { sed -n "s/^[[:space:]]*$1: \([0-9][0-9]*\)\$/\1/p" <<<"$out" | head -1; }
for dir in MC details issues features; do
  out="$("$CSTEST" "tests/$dir" 2>&1)"; rc=$?
  total="$(num Total)"; ok="$(num Successful)"; sk="$(num Skipped)"; bad="$(num Failed)"
  if [ -z "$total" ] || [ "${total:-0}" -eq 0 ]; then
    echo "FAIL tests/$dir: no test summary from cstest (rc=$rc)"; failed=$((failed + 1)); continue
  fi
  echo "tests/$dir: total=$total ok=$ok skipped=$sk failed=$bad rc=$rc"
  passed=$((passed + ok)); skipped=$((skipped + sk)); failed=$((failed + bad))
  [ "$rc" -eq 0 ] || [ "${bad:-0}" -gt 0 ] || failed=$((failed + 1))
done

# Negative tests: these files contain deliberately wrong or malformed expectations, so cstest MUST report failure.
for f in tests/negative/*.yaml; do
  out="$("$CSTEST" "$f" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && grep -Eq "(Failed|Errors): [1-9]" <<<"$out"; then passed=$((passed + 1))
  else echo "FAIL $f: cstest did not flag a deliberately wrong expectation (rc=$rc)"; failed=$((failed + 1)); fi
done

# cstool known-answer checks (arch, hex bytes -> expected disassembly text).
check() { # <arch> <hex> <expected mnemonic+operands>
  local got
  got="$("$CSTOOL" "$1" "$2" 2>&1 | sed -n '1p' | sed 's/^ *[0-9a-f]*  *\(\([0-9a-f][0-9a-f] \)*\) *//; s/[[:space:]]\+/ /g; s/ $//')"
  if [ "$got" = "$3" ]; then passed=$((passed + 1)); else echo "FAIL cstool $1 $2: got '$got', want '$3'"; failed=$((failed + 1)); fi
}
check x64 "55" "push rbp"
check x64 "4889e5" "mov rbp, rsp"
check x32 "90" "nop"
check arm "0100a0e3" "mov r0, #1"
check aarch64 "000080d2" "mov x0, #0"
check riscv64 "13050000" "li a0, 0"

emit_ctrf "cstest" "$passed" "$failed" "$skipped"
