#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$PLUGIN_DIR/hooks/pre-bash-zensu-gate.sh"

. "$PLUGIN_DIR/tests/structure/lib/text-checks.sh"
. "$PLUGIN_DIR/hooks/lib/zensu-cli-map.sh"
. "$PLUGIN_DIR/hooks/lib/zensu-mcp-tools.sh"

ALIASES="$(sed -n 's/.*const ALIAS = {\([^}]*\)};.*/\1/p' "$GATE" | head -1 | tr ',' '\n' | tr -d '"' | tr ':' ' ')"
noun_of() {
  printf '%s\n' "$ALIASES" | awk -v n="$1" '$1 == n { print $2; found = 1 } END { if (!found) print n }'
}
undeclared() {
  printf '%s\n' "$1" | tr '`();|&' '\n\n\n\n\n\n' | awk '
    function word(t) { return match(t, /^[a-z][a-z-]*/) ? substr(t, 1, RLENGTH) : "" }
    {
      for (s = 1; s <= NF; s++) {
        if ($s !~ /zensu$/) continue
        noun = ""
        for (k = s + 1; k <= NF; k++) {
          if ($k == "--api-url") { k++; continue }
          if (substr($k, 1, 1) == "-") continue
          noun = word($k); break
        }
        if (noun == "") continue
        verb = ""
        for (m = k + 1; m <= NF; m++) {
          if ($m == "--api-url") { m++; continue }
          if (substr($m, 1, 1) == "-") continue
          verb = word($m); break
        }
        print noun, verb
      }
    }' \
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

check "D6 the check skips a flag between noun and verb the way the write-gate does" \
  "$([ "$(undeclared 'Run `zensu features --json update <feature-uuid>`.' '')" = update_feature ] && echo PASS || echo FAIL)"

check "D7 the check skips the value of a bare --api-url before the noun and between noun and verb the way the write-gate does" "$(all \
  "$([ "$(undeclared 'Run `zensu --api-url https://x features update <feature-uuid>`.' '')" = update_feature ] && echo PASS || echo FAIL)" \
  "$([ "$(undeclared 'Run `zensu features --api-url https://x update <feature-uuid>`.' '')" = update_feature ] && echo PASS || echo FAIL)")"

check "D8 the check skips a --flag=value before the noun the way the write-gate does" \
  "$([ "$(undeclared 'Run `zensu --api-url=https://x security classify <feature-uuid>`.' '')" = set_security_classification ] && echo PASS || echo FAIL)"

check "D9 the check ends a command at the write-gate's command boundaries" \
  "$([ -z "$(undeclared 'Run `zensu features --json`; update the title by hand.' '')" ] && echo PASS || echo FAIL)"

check "D10 the check reads a verb that ends a sentence as the bare verb" \
  "$([ "$(undeclared 'Then run zensu features update.' '')" = update_feature ] && echo PASS || echo FAIL)"

check "D11 the check finds a zensu command in the middle of a line, as in a collapsed code block" "$(all \
  "$([ "$(undeclared 'Then run zensu features update <feature-uuid> by hand.' '')" = update_feature ] && echo PASS || echo FAIL)" \
  "$([ "$(undeclared 'cat <<EOF x EOF zensu security classify <feature-uuid>' '')" = set_security_classification ] && echo PASS || echo FAIL)")"

echo "----"
echo "test-skill-declared-tools: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
