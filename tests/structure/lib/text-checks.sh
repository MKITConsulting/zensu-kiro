#!/bin/bash

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
all() { for v in "$@"; do [ "$v" = PASS ] || { echo FAIL; return; }; done; echo PASS; }
has() { printf '%s' "$1" | grep -qF -- "$2" && echo PASS || echo FAIL; }
lacks() { printf '%s' "$1" | grep -qF -- "$2" && echo FAIL || echo PASS; }
before() {
  T="$1" A="$2" B="$3" awk 'BEGIN {
    i = index(ENVIRON["T"], ENVIRON["A"]); j = index(ENVIRON["T"], ENVIRON["B"])
    print ((i > 0 && j > i) ? "PASS" : "FAIL")
  }'
}

raw_section() {
  awk -v start="$1" -v stop="$2" 'index($0, start) == 1 {p = 1} p && stop != "" && index($0, stop) == 1 {exit} p' "$SKILL_MD"
}
section() { raw_section "$1" "$2" | tr -s '[:space:]' ' '; }

export FEATURE_CMD_RE='zensu (features (get|update|status|revision|history|split|merge|deprecate)|subfeatures (add|list|promote)|security (classify|analyze|validate|add-test|review|suggest-tests|threat-model)|tiers set-feature|link (test|docs|source)|doc gen-context) <[^>]*>'
uuid_args() {
  local found
  found="$(printf '%s\n' "$1" | grep -oE -- "$2")"
  [ -n "$found" ] && ! printf '%s\n' "$found" | grep -qvE -- ' <feature-uuid>$' && echo PASS || echo FAIL
}
