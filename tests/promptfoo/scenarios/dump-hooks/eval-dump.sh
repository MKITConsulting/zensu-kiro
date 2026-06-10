#!/usr/bin/env bash
# Hook payload recorder for the diagnostics variant agent. Appends the raw
# stdin payload as one JSONL line to <payload cwd>/.zensu-dump/<event>.jsonl —
# the cwd is taken from the payload itself because the hook process's own
# working directory is not guaranteed to be the session project dir.
set -u
EVENT="${1:-unknown}"
P="$(cat 2>/dev/null || true)"
[ -n "$P" ] || exit 0
D=""
if command -v node >/dev/null 2>&1; then
  D="$(PAYLOAD="$P" node -e 'try{const j=JSON.parse(process.env.PAYLOAD||"{}");process.stdout.write(typeof j.cwd==="string"?j.cwd:"")}catch(_){}' 2>/dev/null)"
fi
[ -n "$D" ] && [ -d "$D" ] || D="$PWD"
mkdir -p "$D/.zensu-dump" 2>/dev/null || exit 0
printf '%s\n' "$P" >> "$D/.zensu-dump/${EVENT}.jsonl" 2>/dev/null || true
exit 0
