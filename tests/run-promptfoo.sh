#!/usr/bin/env bash
# Live promptfoo eval runner for zensu-kiro. NEVER part of the deterministic CI
# gate: it drives a real `kiro-cli` (logged-in session or KIRO_API_KEY) and
# costs credits.
#
#   bash tests/run-promptfoo.sh diagnostics   # risk-register suite (D1-D6)
#   bash tests/run-promptfoo.sh behavior      # regression suite (B1-B6)
#
# Env:
#   RUN_SLOW=1            include "[slow]" tests (B5 full TDD run)
#   ANTHROPIC_API_KEY     enables "[rubric]" tests (filtered out otherwise)
#   PROMPTFOO_VERSION     pin (default 0.121)
set -u

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
PF_DIR="$TESTS_DIR/promptfoo"
SUITE="${1:-diagnostics}"

case "$SUITE" in
  diagnostics) CONFIG="$PF_DIR/diagnostics.yaml" ;;
  behavior)    CONFIG="$PF_DIR/promptfooconfig.yaml" ;;
  *) echo "usage: $0 [diagnostics|behavior]" >&2; exit 2 ;;
esac

command -v kiro-cli >/dev/null 2>&1 || { echo "FATAL: kiro-cli not on PATH" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FATAL: node required" >&2; exit 1; }
if ! kiro-cli whoami >/dev/null 2>&1 && [ -z "${KIRO_API_KEY:-}" ]; then
  echo "FATAL: not logged in (kiro-cli login) and KIRO_API_KEY unset" >&2
  exit 1
fi

PF="promptfoo@${PROMPTFOO_VERSION:-0.121}"
RESULTS="$PF_DIR/results"
mkdir -p "$RESULTS"
OUT="$RESULTS/$SUITE-$(date +%Y%m%d-%H%M%S).json"

FILTER_ARGS=()
if [ "${RUN_SLOW:-0}" != "1" ]; then
  FILTER_ARGS+=(--filter-pattern '^(?!\[slow\])')
fi
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then
  # exclude rubric-graded tests when no grading key is available
  if [ "${RUN_SLOW:-0}" != "1" ]; then
    FILTER_ARGS=(--filter-pattern '^(?!\[slow\]|\[rubric\])')
  else
    FILTER_ARGS=(--filter-pattern '^(?!\[rubric\])')
  fi
fi

echo "suite=$SUITE config=$CONFIG promptfoo=$PF (serial, no cache)"
cd "$PF_DIR"
npx -y "$PF" eval -c "$CONFIG" --no-cache -j 1 --output "$OUT" "${FILTER_ARGS[@]}"
RC=$?
echo "results: $OUT"
exit "$RC"
