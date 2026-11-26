#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$PLUGIN_DIR/hooks/pre-bash-zensu-gate.sh"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}
all() { for v in "$@"; do [ "$v" = PASS ] || { echo FAIL; return; }; done; echo PASS; }

. "$PLUGIN_DIR/hooks/lib/zensu-cli-map.sh"
. "$PLUGIN_DIR/hooks/lib/zensu-mcp-tools.sh"

ALIASES="$(sed -n 's/.*const ALIAS = {\([^}]*\)};.*/\1/p' "$GATE" | head -1 | tr ',' '\n' | tr -d '"' | tr ':' ' ')"
noun_of() {
  printf '%s\n' "$ALIASES" | awk -v n="$1" '$1 == n { print $2; found = 1 } END { if (!found) print n }'
}
undeclared() {
  printf '%s\n' "$1" | grep -oE -- 'zensu( -[-a-z]+)* [a-z][a-z-]* [a-z][a-z-]*' \
    | awk '{ i = 2; while (i <= NF && substr($i, 1, 1) == "-") i++; print $i, $(i + 1) }' \
    | sort -u | while read -r noun verb; do
      tool="$(zensu_cli_to_tool "$(noun_of "$noun")" "$verb")"
      { [ -n "$tool" ] && zensu_is_mutation_tool "$tool"; } || continue
      case ",$2," in *",$tool,"*) ;; *) echo "$tool" ;; esac
    done
}

check "D1 the write-gate's noun alias table is readable and maps feature to features" "$(all \
  "$([ -n "$ALIASES" ] && echo PASS || echo FAIL)" \
  "$([ "$(noun_of feature)" = features ] && echo PASS || echo FAIL)" \
  "$([ "$(noun_of sec)" = security ] && echo PASS || echo FAIL)")"

D2_SEEN=0; D2_BAD=""
for f in "$PLUGIN_DIR"/skills/*/SKILL.md; do
  tools="$(sed -n 's/.*--workflow-begin --tools "\([^"]*\)".*/\1/p' "$f" | head -1)"
  [ -n "$tools" ] || continue
  D2_SEEN=$((D2_SEEN+1))
  missing="$(undeclared "$(tr -s '[:space:]' ' ' < "$f")" "$tools" | sort -u | tr '\n' ' ')"
  [ -z "$missing" ] || D2_BAD="$D2_BAD [$(basename "$(dirname "$f")"): $missing]"
done
check "D2 every skill with a --workflow-begin --tools list declares the tool of every mutating zensu command it names ($D2_SEEN skills)${D2_BAD:+ (undeclared:$D2_BAD)}" "$(all \
  "$([ "$D2_SEEN" -ge 4 ] && echo PASS || echo FAIL)" \
  "$([ -z "$D2_BAD" ] && echo PASS || echo FAIL)")"

D3_TEXT='Run `zensu security classify <feature-uuid>`, then `zensu features list --product <product-id> --json`.'
check "D3 the check names an undeclared mutation and passes a declared one or a read" "$(all \
  "$([ "$(undeclared "$D3_TEXT" 'update_feature')" = set_security_classification ] && echo PASS || echo FAIL)" \
  "$([ -z "$(undeclared "$D3_TEXT" 'update_feature,set_security_classification')" ] && echo PASS || echo FAIL)" \
  "$([ -z "$(undeclared 'Run `zensu features list --product <product-id> --json` once.' '')" ] && echo PASS || echo FAIL)")"

check "D4 the check reads an aliased noun the way the write-gate does" "$(all \
  "$([ "$(undeclared 'Run `zensu feature deprecate <feature-uuid>`.' 'update_feature')" = deprecate_feature ] && echo PASS || echo FAIL)" \
  "$([ "$(undeclared 'Run `zensu sec classify <feature-uuid>`.' '')" = set_security_classification ] && echo PASS || echo FAIL)")"

check "D5 the check skips flags before the noun the way the write-gate does" \
  "$([ "$(undeclared 'Run `zensu --json features update <feature-uuid>`.' '')" = update_feature ] && echo PASS || echo FAIL)"

echo "----"
echo "test-skill-declared-tools: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
