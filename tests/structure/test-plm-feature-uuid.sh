#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
PLM_CLI="$PLUGIN_DIR/agents/prompts/zensu-plm.md"
PLM_IDE="$PLUGIN_DIR/agents/ide/zensu-plm.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

P1_MISSING=""
for f in "$PLM_CLI" "$PLM_IDE"; do
  [ -f "$f" ] || P1_MISSING="$P1_MISSING ${f#"$PLUGIN_DIR"/}"
done
if [ -n "$P1_MISSING" ]; then
  check "P1 both zensu-plm prompts exist (missing:$P1_MISSING)" FAIL
  echo "----"
  echo "test-plm-feature-uuid: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "P1 both zensu-plm prompts exist" PASS

has() { printf '%s' "$1" | grep -qF -- "$2" && echo PASS || echo FAIL; }
lacks() { printf '%s' "$1" | grep -qF -- "$2" && echo FAIL || echo PASS; }
before() {
  T="$1" A="$2" B="$3" awk 'BEGIN {
    i = index(ENVIRON["T"], ENVIRON["A"]); j = index(ENVIRON["T"], ENVIRON["B"])
    print ((i > 0 && j > i) ? "PASS" : "FAIL")
  }'
}
all() { for v in "$@"; do [ "$v" = PASS ] || { echo FAIL; return; }; done; echo PASS; }

CLI_WHOLE="$(tr -s '[:space:]' ' ' < "$PLM_CLI")"
IDE_WHOLE="$(tr -s '[:space:]' ' ' < "$PLM_IDE")"
CLI_IDS="$(grep -F -- '**Feature IDs**' "$PLM_CLI" | tr -s '[:space:]' ' ')"
IDE_IDS="$(grep -F -- '**Feature IDs**' "$PLM_IDE" | tr -s '[:space:]' ' ')"
PRODUCTS_CMD='zensu products list --json'
FEATURES_CMD='zensu features list --product <product-id> --json'

RULE='`KEY-N` is the human-facing id only: every CLI feature argument, written `<feature-uuid>` below, takes the feature **UUID** and rejects a `KEY-N` id or slug with HTTP 400 `invalid feature id`; the `--feature` flag of `zensu journeys step` takes the feature UUID too.'
RESOLVE="Resolve \`KEY-N\` → UUID via \`$PRODUCTS_CMD\` (match \`feature_key\`) → \`$FEATURES_CMD\` (match \`number\` or \`slug\`)."
ASK='A slug carries no `KEY`: when the product is not known yet, ask the user which product the slug belongs to. If no entry or more than one matches, ask the user instead of guessing.'
check "P2 the Feature IDs paragraph of both prompts says every <feature-uuid> argument and the journey step --feature flag take the feature UUID, resolves KEY-N through feature_key, then number or slug, and asks instead of guessing" "$(all \
  "$(has "$CLI_IDS" "$RULE")" \
  "$(has "$IDE_IDS" "$RULE")" \
  "$(has "$CLI_IDS" "$RESOLVE")" \
  "$(has "$IDE_IDS" "$RESOLVE")" \
  "$(has "$CLI_IDS" "$ASK")" \
  "$(has "$IDE_IDS" "$ASK")" \
  "$(before "$CLI_IDS" "$PRODUCTS_CMD" "$FEATURES_CMD")" \
  "$(before "$IDE_IDS" "$PRODUCTS_CMD" "$FEATURES_CMD")")"

GET_LINE='- `zensu features get <feature-uuid>` — Get full feature details. The id must be the feature **UUID**; a slug or KEY-N id is rejected with HTTP 400 `invalid feature id`.'
check "P3 the zensu features get line of both prompts says the id must be the feature UUID" "$(all \
  "$(has "$CLI_WHOLE" "$GET_LINE")" \
  "$(has "$IDE_WHOLE" "$GET_LINE")")"

FEATURE_CMD_RE='zensu (features (get|update|status|revision|history|split|merge|deprecate)|subfeatures (add|list|promote)|security (classify|analyze|validate|add-test|review|suggest-tests|threat-model)|tiers set-feature|link (test|docs|source)|doc gen-context) <[^>]*>'
feature_args() {
  local found
  found="$(printf '%s\n' "$1" | grep -oE -- "$FEATURE_CMD_RE")"
  [ -n "$found" ] && ! printf '%s\n' "$found" | grep -qvE -- ' <feature-uuid>$' && echo PASS || echo FAIL
}
P4_MISSING=""
for c in 'features get' 'features update' 'features status' 'features revision' 'features history' \
  'features split' 'features merge' 'features deprecate' 'subfeatures add' 'subfeatures list' 'subfeatures promote' \
  'link test' 'link docs' 'link source' 'security classify' 'security analyze' 'security validate' 'security add-test' \
  'security review' 'security suggest-tests' 'security threat-model' 'tiers set-feature' 'doc gen-context'; do
  printf '%s' "$CLI_WHOLE" | grep -qF -- "zensu $c <feature-uuid>" || P4_MISSING="$P4_MISSING [prompts: $c]"
  printf '%s' "$IDE_WHOLE" | grep -qF -- "zensu $c <feature-uuid>" || P4_MISSING="$P4_MISSING [ide: $c]"
done
check "P4 every feature-scoped zensu command in both prompts names <feature-uuid>, none <feature-id>, <id> or another placeholder${P4_MISSING:+ (missing:$P4_MISSING)}" "$(all \
  "$(feature_args "$CLI_WHOLE")" \
  "$(feature_args "$IDE_WHOLE")" \
  "$([ -z "$P4_MISSING" ] && echo PASS || echo FAIL)" \
  "$(lacks "$CLI_WHOLE" '<feature-id>')" \
  "$(lacks "$IDE_WHOLE" '<feature-id>')")"

check "P5 the status rule and the positional-id rule of both prompts name <feature-uuid>" "$(all \
  "$(has "$CLI_WHOLE" 'Status changes go through `zensu features status <feature-uuid> <new-status>`')" \
  "$(has "$IDE_WHOLE" 'Status changes go through `zensu features status <feature-uuid> <new-status>`')" \
  "$(has "$CLI_WHOLE" 'IDs that are path segments are positional args (e.g. `zensu features get <feature-uuid>`)')" \
  "$(has "$IDE_WHOLE" 'IDs that are path segments are positional args (e.g. `zensu features get <feature-uuid>`)')")"

P6_GOOD='Run `zensu security classify <feature-uuid>`, then `zensu features status <feature-uuid> <new-status>`.'
P6_ID='Run `zensu security classify <feature-uuid>`, then `zensu features revision <id>`.'
P6_KEY='Run `zensu link test <feature-id>` once.'
P6_NONE='Run `zensu security posture <product-id>` once.'
check "P6 the argument check passes <feature-uuid>-only text and fails a <feature-id>, <id> or other placeholder, or text without a feature call" "$(all \
  "$(feature_args "$P6_GOOD")" \
  "$([ "$(feature_args "$P6_ID")" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(feature_args "$P6_KEY")" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(feature_args "$P6_NONE")" = FAIL ] && echo PASS || echo FAIL)")"

P7_GOOD="Resolve via \`$PRODUCTS_CMD\` → \`$FEATURES_CMD\`."
P7_LATE="Read \`$FEATURES_CMD\`, then \`$PRODUCTS_CMD\`."
P7_NONE="Read \`$FEATURES_CMD\`."
check "P7 the order check passes products-before-features text and fails a late or a missing products read" "$(all \
  "$(before "$P7_GOOD" "$PRODUCTS_CMD" "$FEATURES_CMD")" \
  "$([ "$(before "$P7_LATE" "$PRODUCTS_CMD" "$FEATURES_CMD")" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(before "$P7_NONE" "$PRODUCTS_CMD" "$FEATURES_CMD")" = FAIL ] && echo PASS || echo FAIL)")"

STEP_LINE='- `zensu journeys step <journey-id> --product <id>` — Add a step to a journey (`--title` and `--step-order` required; `--feature` takes the feature **UUID**; `--interaction-type` action|navigation|input|validation|output|wait)'
check "P8 the zensu journeys step line of both prompts says --feature takes the feature UUID" "$(all \
  "$(has "$CLI_WHOLE" "$STEP_LINE")" \
  "$(has "$IDE_WHOLE" "$STEP_LINE")")"

STEP7="7. **After apply, discover user journeys:** map drafted journeys to the new features' UUIDs (each entry's \`id\` in \`$FEATURES_CMD\`) and create them with \`zensu journeys create\` + \`zensu journeys step --feature <feature-uuid>\`, then \`zensu journeys health\`"
check "P9 the ghost-scan pattern of both prompts links each journey step to a feature by the UUID from the feature list" "$(all \
  "$(has "$CLI_WHOLE" "$STEP7")" \
  "$(has "$IDE_WHOLE" "$STEP7")" \
  "$(lacks "$CLI_WHOLE" 'map drafted journeys to the new feature IDs')" \
  "$(lacks "$IDE_WHOLE" 'map drafted journeys to the new feature IDs')")"

echo "----"
echo "test-plm-feature-uuid: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
