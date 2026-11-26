#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
. "$PLUGIN_DIR/tests/structure/lib/text-checks.sh"
SKILL_MD="$PLUGIN_DIR/skills/zensu-ghost-scan/SKILL.md"

if [ ! -f "$SKILL_MD" ]; then
  check "G1 skills/zensu-ghost-scan/SKILL.md exists" FAIL
  echo "----"
  echo "test-ghost-scan-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "G1 skills/zensu-ghost-scan/SKILL.md exists" PASS

PHASE5="$(section '### Phase 5:' '### Phase 6')"
CLI_TABLE="$(section '## CLI Commands Used' '')"
WHOLE="$(tr -s '[:space:]' ' ' < "$SKILL_MD")"
LIST_CMD='zensu features list --product <product-id> --json'
STEP_CMD='zensu journeys step <journey-id> --product <product-id>'

check "G2 Phase 5 reads the applied features with --json and maps each draft slug to its <feature-uuid>" "$(all \
  "$(has "$PHASE5" 'close that gap here, **after `zensu ghost apply`**, when the features exist.')" \
  "$(has "$PHASE5" "1. Run \`$LIST_CMD\` and build a slug → \`id\` map from the just-applied features: each entry's \`id\` is the feature's UUID, written \`<feature-uuid>\`, the value \`zensu journeys step --feature\` takes.")" \
  "$(has "$PHASE5" "Resolve each draft step's candidate slug to its \`<feature-uuid>\` via the map.")")"

check "G3 Phase 5 passes --feature <feature-uuid> to zensu journeys step, after the feature list is read" "$(all \
  "$(has "$PHASE5" "\`$STEP_CMD\` per step (\`--step-order\` 1-based, \`--feature <feature-uuid>\`,")" \
  "$(before "$PHASE5" "$LIST_CMD" "$STEP_CMD")" \
  "$(before "$PHASE5" "$LIST_CMD" '`--feature <feature-uuid>`')")"

check "G4 Phase 5 builds no ZEN-ID map, reads no --compact list and passes no bare --feature" "$(all \
  "$(lacks "$PHASE5" 'ZEN-ID')" \
  "$(lacks "$PHASE5" 'ZEN IDs')" \
  "$(lacks "$PHASE5" '--compact')" \
  "$(lacks "$PHASE5" '`--feature`,')" \
  "$(lacks "$WHOLE" 'slug → ZEN-ID')" \
  "$(lacks "$WHOLE" 'to a real `feature_id`')")"

check "G5 the CLI table maps each slug to its <feature-uuid> and links journey steps by it" "$(all \
  "$(has "$CLI_TABLE" '| `zensu features list` | 1, 5, 6 | Load existing features (dedup); map each slug to its `<feature-uuid>` after apply |')" \
  "$(has "$CLI_TABLE" '| `zensu journeys step` | 5 | Add ordered steps linking each feature by its `<feature-uuid>` |')")"

check "G6 Phase 2b keeps draft journeys abstract until apply because journey steps need feature UUIDs" \
  "$(has "$WHOLE" 'since `zensu journeys step` needs real feature UUIDs that exist only after Phase 4')"

G7_GOOD="Run \`$LIST_CMD\`, then \`$STEP_CMD\` per step."
G7_LATE="Run \`$STEP_CMD\` per step, then \`$LIST_CMD\`."
G7_NONE="Run \`$STEP_CMD\` per step."
check "G7 the order check passes list-before-step text and fails a late or a missing list read" "$(all \
  "$(before "$G7_GOOD" "$LIST_CMD" "$STEP_CMD")" \
  "$([ "$(before "$G7_LATE" "$LIST_CMD" "$STEP_CMD")" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(before "$G7_NONE" "$LIST_CMD" "$STEP_CMD")" = FAIL ] && echo PASS || echo FAIL)")"

echo "----"
echo "test-ghost-scan-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
