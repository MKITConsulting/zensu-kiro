#!/bin/bash
# Master test runner for the zensu-kiro port.
#
#   (no arg)   DETERMINISTIC suites only — no network, no API spend:
#                - every tests/structure/test-*.sh
#
# Live promptfoo evals are NOT part of this gate — run them explicitly via
# `bash tests/run-promptfoo.sh diagnostics|behavior` (requires kiro-cli + auth).
#
# Exit 0 iff every selected suite passed. A "suite" = one script; it passes iff
# it exits 0. Per-script internal tallies are streamed; this runner tallies suites.
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$TESTS_DIR/.." && pwd)"

RESULTS_DIR="$TESTS_DIR/results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$RESULTS_DIR/run-all-$TIMESTAMP.txt"

PASS=0; FAIL=0
log() { printf "%s\n" "$1" | tee -a "$REPORT"; }

run_suite() {
  local label="$1"; shift
  local out
  out="$("$@" 2>&1)"
  local rc=$?
  printf '%s\n' "$out" | sed 's/^/      /' | tee -a "$REPORT" >/dev/null
  if [ "$rc" -eq 0 ]; then
    PASS=$((PASS+1)); log "  PASS  $label"
  else
    FAIL=$((FAIL+1)); log "  FAIL  $label (exit $rc)"
  fi
}

log "════════════════════════════════════════════════════════════"
log "  zensu-kiro — run-all  ($TIMESTAMP)"
log "  version v$(cat "$ROOT/VERSION" 2>/dev/null || echo '?')"
log "════════════════════════════════════════════════════════════"

log ""
log "▸ Structure tests (deterministic)"
for t in "$TESTS_DIR"/structure/test-*.sh; do
  [ -f "$t" ] || continue
  run_suite "structure/$(basename "$t")" bash "$t"
done

log ""
log "════════════════════════════════════════════════════════════"
log "  SUITES: $PASS passed / $FAIL failed"
log "  Report: $REPORT"
log "════════════════════════════════════════════════════════════"

[ "$FAIL" -eq 0 ]
