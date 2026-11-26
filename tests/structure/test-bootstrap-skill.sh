#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="$PLUGIN_DIR/skills/zensu-bootstrap/SKILL.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SKILL_MD" ]; then
  check "B1 skills/zensu-bootstrap/SKILL.md exists" FAIL
  echo "----"
  echo "test-bootstrap-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "B1 skills/zensu-bootstrap/SKILL.md exists" PASS

section() {
  awk -v start="$1" -v stop="$2" 'index($0, start) == 1 {p = 1} p && stop != "" && index($0, stop) == 1 {exit} p' "$SKILL_MD" \
    | tr -s '[:space:]' ' '
}
has() { printf '%s' "$1" | grep -qF -- "$2" && echo PASS || echo FAIL; }
before() {
  T="$1" A="$2" B="$3" awk 'BEGIN {
    i = index(ENVIRON["T"], ENVIRON["A"]); j = index(ENVIRON["T"], ENVIRON["B"])
    print ((i > 0 && j > i) ? "PASS" : "FAIL")
  }'
}
all() { for v in "$@"; do [ "$v" = PASS ] || { echo FAIL; return; }; done; echo PASS; }

STEP1="$(section '**Step 1:' '**Step 2:')"
STEP2="$(section '**Step 2:' '**Step 3:')"
STEP3="$(section '**Step 3:' '**Step 4:')"
STEP4="$(section '**Step 4:' '**Step 5:')"
CLI_TABLE="$(section '## CLI Commands Used' '')"
WHOLE="$(tr -s '[:space:]' ' ' < "$SKILL_MD")"
LIST_CMD='zensu features list --product <product-id> --json'

check "B2 Phase 3 Step 1 reads the feature list as the source of every <feature-uuid>, reads it again after a change, and maps a KEY-N id only within this product" "$(all \
  "$(has "$STEP1" "Review the bootstrapped features with the user (\`$LIST_CMD\`).")" \
  "$(has "$STEP1" '`zensu products bootstrap-apply` returns counts, not feature IDs, so this list is the source of every `<feature-uuid>` in Phase 3')" \
  "$(has "$STEP1" "each entry's \`id\` is the feature's UUID")" \
  "$(has "$STEP1" 'Read it again after any change that adds, splits or removes features, before the next feature-scoped command, and skip entries whose `deprecated_at` is set.')" \
  "$(has "$STEP1" "When the user names a feature by its \`KEY-N\` id or its slug, match \`number\` for a \`KEY-N\` id whose \`KEY\` is the product's \`feature_key\` (\`zensu products get <product-id> --json\`), or \`slug\` for a slug, and take that entry's \`id\`.")" \
  "$(has "$STEP1" "If the \`KEY\` is another product's, or no entry or more than one matches, ask the user instead of guessing.")" \
  "$(has "$STEP1" 'A feature-scoped command fails with HTTP 400 `invalid feature id` when it gets a `KEY-N` id or a slug instead of the UUID')" \
  "$(before "$STEP1" "$LIST_CMD" 'zensu subfeatures add <feature-uuid>')")"

check "B3 Phase 3 Step 3 re-reads the feature list before its first security call and picks the features by security_classification and priority" "$(all \
  "$(has "$STEP3" "Re-read \`$LIST_CMD\` first, since Step 1 may have added, split or removed features")" \
  "$(has "$STEP3" "each entry's \`id\` is the \`<feature-uuid>\` below, and its \`security_classification\` and \`priority\` pick the features")" \
  "$(before "$STEP3" "$LIST_CMD" 'zensu security analyze <feature-uuid>')" \
  "$(before "$STEP3" "$LIST_CMD" 'zensu security suggest-tests <feature-uuid>')" \
  "$(before "$STEP3" "$LIST_CMD" 'zensu security threat-model <feature-uuid>')")"

FEATURE_CMD_RE='zensu (features (get|update|status|revision|history|split|merge|deprecate)|subfeatures (add|list|promote)|security (classify|analyze|validate|add-test|review|suggest-tests|threat-model)|tiers set-feature|link (test|docs|source)|doc gen-context) <[^>]*>'
uuid_args() {
  local found
  found="$(printf '%s\n' "$1" | grep -oE -- "$FEATURE_CMD_RE")"
  [ -n "$found" ] && ! printf '%s\n' "$found" | grep -qvE -- ' <feature-uuid>$' && echo PASS || echo FAIL
}
B4_MISSING=""
for c in 'features deprecate' 'subfeatures add' 'features split' 'features update' 'security classify' \
  'security analyze' 'security suggest-tests' 'security threat-model' 'tiers set-feature'; do
  printf '%s' "$WHOLE" | grep -qF -- "zensu $c <feature-uuid>" || B4_MISSING="$B4_MISSING [$c]"
done
check "B4 every feature-scoped zensu command passes <feature-uuid>, none another placeholder${B4_MISSING:+ (missing:$B4_MISSING)}" "$(all \
  "$(uuid_args "$WHOLE")" \
  "$([ -z "$B4_MISSING" ] && echo PASS || echo FAIL)" \
  "$(has "$STEP1" 'zensu features update <feature-uuid>')" \
  "$(has "$STEP4" 'zensu tiers set-feature <feature-uuid>')")"

check "B5 Phase 3 Step 2 re-reads the feature list before a journey step links a feature by its UUID" "$(all \
  "$(has "$STEP2" "Re-read \`$LIST_CMD\` first, since Step 1 may have added, split or removed features: each entry's \`id\` is the \`<feature-uuid>\` a journey step links through \`--feature\`")" \
  "$(has "$STEP2" 'Link to features via `--feature <feature-uuid>`')" \
  "$(before "$STEP2" "$LIST_CMD" 'Link to features via `--feature <feature-uuid>`')")"

check "B6 the CLI table names every step that reads the feature list, and lists the KEY check and the classification setter" "$(all \
  "$(has "$CLI_TABLE" "| \`zensu features list\` | 3.1, 3.2, 3.3 | Review bootstrapped features; each entry's \`id\` is the \`<feature-uuid>\` the feature-scoped commands take |")" \
  "$(has "$CLI_TABLE" "| \`zensu products get\` | 3.1 | Read the product's \`feature_key\` to check the \`KEY\` of a \`KEY-N\` id the user names |")" \
  "$(has "$CLI_TABLE" '| `zensu security classify` | 3.1 | Fix security classifications |')" \
  "$(has "$CLI_TABLE" '| `zensu features deprecate` | 3.1 | Remove features that should not be tracked |')")"

B7_GOOD='Run `zensu security analyze <feature-uuid>`, then `zensu tiers set-feature <feature-uuid>`.'
B7_KEY='Run `zensu security analyze <feature-uuid>`, then `zensu subfeatures add <feature-id>`.'
B7_ID='Run `zensu features update <id>` once.'
B7_NONE='Run `zensu features list --product <product-id> --json` once.'
check "B7 the UUID-argument check passes UUID-only text and fails a <feature-id> or <id> placeholder, or text without a feature call" "$(all \
  "$(uuid_args "$B7_GOOD")" \
  "$([ "$(uuid_args "$B7_KEY")" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(uuid_args "$B7_ID")" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(uuid_args "$B7_NONE")" = FAIL ] && echo PASS || echo FAIL)")"

B8_GOOD="Re-read \`$LIST_CMD\` first, then run \`zensu security analyze <feature-uuid>\`."
B8_LATE="Run \`zensu security analyze <feature-uuid>\`, then re-read \`$LIST_CMD\`."
B8_NONE='Run `zensu security analyze <feature-uuid>`.'
check "B8 the order check passes list-before-security text and fails a late or a missing list read" "$(all \
  "$(before "$B8_GOOD" "$LIST_CMD" 'zensu security analyze <feature-uuid>')" \
  "$([ "$(before "$B8_LATE" "$LIST_CMD" 'zensu security analyze <feature-uuid>')" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(before "$B8_NONE" "$LIST_CMD" 'zensu security analyze <feature-uuid>')" = FAIL ] && echo PASS || echo FAIL)")"

. "$PLUGIN_DIR/hooks/lib/zensu-cli-map.sh"
TOOLS="$(sed -n 's/.*--workflow-begin --tools "\([^"]*\)".*/\1/p' "$SKILL_MD" | head -1)"
check "B9 the --workflow-begin --tools list declares the classification and removal tools Step 1 uses (every skill's full list is pinned by test-skill-declared-tools.sh)" "$(all \
  "$([ "$(zensu_cli_to_tool security classify)" = set_security_classification ] && echo PASS || echo FAIL)" \
  "$([ "$(zensu_cli_to_tool features deprecate)" = deprecate_feature ] && echo PASS || echo FAIL)" \
  "$(has ",$TOOLS," ',set_security_classification,')" \
  "$(has ",$TOOLS," ',deprecate_feature,')")"

check "B10 Phase 3 Step 1 fixes priorities with features update --priority and classifications with security classify --classification" \
  "$(has "$STEP1" 'Fix incorrect priorities with `zensu features update <feature-uuid> --priority <low|medium|high|critical>` and incorrect security classifications with `zensu security classify <feature-uuid> --classification <public|internal|confidential|restricted>`')"

check "B11 Phase 3 Step 1 removes untracked features with features deprecate" \
  "$(has "$STEP1" "Remove horizontal/implementation features that shouldn't be tracked with \`zensu features deprecate <feature-uuid> --reason <reason>\`")"

echo "----"
echo "test-bootstrap-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
