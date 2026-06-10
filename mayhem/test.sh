#!/usr/bin/env bash
#
# libvnc/mayhem/test.sh — RUN libvncserver's own ctest suite (built by mayhem/build.sh with normal
# flags) and emit a CTRF summary. Exit 0 iff no test failed.
#
# PATCH-grade oracle: these are libvncserver's real assertion tests, not "exit 0" checks —
#   turbojpeg : tjunittest, a known-answer JPEG (de)compression suite that ABORTS on any pixel
#               mismatch against its built-in reference buffers.
#   wstest    : decodes recorded WebSocket frames and asserts the decoded bytes match expected.
#   cargs     : argument-parser unit test with asserted parse results.
#   includetest_server/client : assert the public headers compile standalone.
# A no-op / "exit(0)" patch (or one that corrupts the (de)coders) makes tjunittest/wstest fail, so
# "ran the corpus, exit 0" cannot pass this oracle. This script only RUNS the pre-built suite via
# ctest; it never compiles.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC" 2>/dev/null || true

BUILDDIR="$SRC/mayhem-tests"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

if [ ! -d "$BUILDDIR" ]; then
  echo "missing $BUILDDIR — run mayhem/build.sh first" >&2
  emit_ctrf "ctest" 0 1 0; exit 2
fi
if ! command -v ctest >/dev/null 2>&1; then
  echo "ctest not available — cannot run the test suite" >&2
  emit_ctrf "ctest" 0 1 0; exit 2
fi

echo "=== running ctest in $BUILDDIR ==="
out="$(ctest --test-dir "$BUILDDIR" --output-on-failure -V -j"$(nproc)" 2>&1)"; rc=$?
echo "$out"

# ctest summary line: "X% tests passed, Y tests failed out of Z"
PASSPCT_LINE="$(printf '%s\n' "$out" | sed -n 's/.*tests passed, \([0-9][0-9]*\) tests failed out of \([0-9][0-9]*\).*/\1 \2/p' | tail -1)"
FAILED="$(echo "$PASSPCT_LINE" | awk '{print $1}')"
TOTAL="$(echo "$PASSPCT_LINE"  | awk '{print $2}')"

if [ -z "${TOTAL:-}" ] || [ -z "${FAILED:-}" ]; then
  echo "could not parse ctest summary; using ctest exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "ctest" 1 0 0; exit 0; }
  emit_ctrf "ctest" 0 1 0; exit 1
fi
PASSED=$(( TOTAL - FAILED ))

# Ensure at least one test ran (TOTAL > 0) to prevent exit(0)-only bypasses.
if [ "$TOTAL" -le 0 ]; then
  echo "ERROR: ctest reported 0 tests — no actual test execution" >&2
  emit_ctrf "ctest" 0 1 0; exit 1
fi

# Verify actual test execution by checking for test-binary-specific output.
# The actual test binaries (not shell script helpers) must produce observable output:
#   - tjunittest: JPEG test output (e.g., "Result in test_", "RGB Top-Down", timing > 1 sec)
#   - wstest: test frame assertions (e.g., "PASS:" lines)
#   - cargstest: assertion results (shows actual test output, not just exit 0)
# When sabotaged to exit(0), these binaries produce zero output. The shell script tests
# (includetest.sh) will still output "Built target..." from gmake, so we exclude that pattern.
# Look for lines that ONLY come from actual test binary execution:
REAL_TEST_MARKERS="$(printf '%s\n' "$out" | grep -vE '(Built target|Install|-- )' | grep -cE '(PASS:|FAIL:|Result in test_|ms$|Top-Down|Bottom-Up)')"
if [ "$REAL_TEST_MARKERS" -lt 3 ]; then
  echo "ERROR: ctest tests produced insufficient output markers from actual test binaries (found $REAL_TEST_MARKERS, expected > 2)" >&2
  emit_ctrf "ctest" 0 1 0; exit 1
fi

emit_ctrf "ctest" "$PASSED" "$FAILED" 0
