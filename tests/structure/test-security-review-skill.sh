#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="$PLUGIN_DIR/skills/zensu-security-review/SKILL.md"
PLM_CLI="$PLUGIN_DIR/agents/prompts/zensu-plm.md"
PLM_IDE="$PLUGIN_DIR/agents/ide/zensu-plm.md"

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SKILL_MD" ]; then
  check "M1 skills/zensu-security-review/SKILL.md exists" FAIL
  echo "----"
  echo "test-security-review-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "M1 skills/zensu-security-review/SKILL.md exists" PASS

section() {
  awk -v start="$1" -v stop="$2" 'index($0, start) == 1 {p = 1} p && stop != "" && index($0, stop) == 1 {exit} p' "$SKILL_MD" \
    | tr -s '[:space:]' ' '
}
flat() { [ -f "$1" ] && tr -s '[:space:]' ' ' < "$1"; }
has() { printf '%s' "$1" | grep -qF -- "$2" && echo PASS || echo FAIL; }
lacks() { printf '%s' "$1" | grep -qF -- "$2" && echo FAIL || echo PASS; }
before() {
  T="$1" A="$2" B="$3" awk 'BEGIN {
    i = index(ENVIRON["T"], ENVIRON["A"]); j = index(ENVIRON["T"], ENVIRON["B"])
    print ((i > 0 && j > i) ? "PASS" : "FAIL")
  }'
}
all() { for v in "$@"; do [ "$v" = PASS ] || { echo FAIL; return; }; done; echo PASS; }

PREREQ="$(section '## Prerequisites' '## Workflow')"
STEP1="$(section '### Step 1:' '### Step 2:')"
STEP6="$(section '### Step 6:' '### Step 7:')"
STEP7="$(section '### Step 7:' '### Summary')"
CLI_TABLE="$(section '## CLI Commands Used' '')"
WHOLE="$(tr -s '[:space:]' ' ' < "$SKILL_MD")"
PLM_CLI_TEXT="$(flat "$PLM_CLI")"
PLM_IDE_TEXT="$(flat "$PLM_IDE")"

check "M2 the prerequisites say every feature-scoped zensu security command takes the feature's UUID and a KEY-N id or a slug fails with HTTP 400" "$(all \
  "$(has "$PREREQ" 'The user may name it as a `KEY-N` id (e.g. `ZEN-42`), a slug or a UUID')" \
  "$(has "$PREREQ" "but every feature-scoped \`zensu security\` command below takes the feature's UUID, written \`<feature-uuid>\`")" \
  "$(has "$PREREQ" 'a `KEY-N` id or a slug fails with HTTP 400 `invalid feature id`. Step 1 resolves the ID first.')")"

check "M3 Step 1 resolves a non-UUID ID through the product's feature_key and its feature list before the first feature call" "$(all \
  "$(has "$STEP1" 'Ask the user for the feature ID. If it is not a UUID, resolve it before the first feature call:')" \
  "$(has "$STEP1" '`zensu products list --json` → the product whose `feature_key` matches the `KEY` prefix')" \
  "$(has "$STEP1" '(a slug has none: ask the user which product it belongs to)')" \
  "$(has "$STEP1" '→ `zensu features list --product <product-id> --json`, then match `number` for a `KEY-N` id or `slug` for a slug')" \
  "$(has "$STEP1" "The matching entry's \`id\` is the \`<feature-uuid>\` every later step passes")" \
  "$(has "$STEP1" 'If no entry or more than one matches, ask the user instead of guessing')" \
  "$(before "$STEP1" 'zensu products list --json' 'zensu features list --product <product-id> --json')" \
  "$(before "$STEP1" 'zensu features list --product <product-id> --json' 'zensu security classify <feature-uuid>')" \
  "$(before "$STEP1" 'zensu features list --product <product-id> --json' 'zensu security analyze <feature-uuid>')")"

FEATURE_CMD_RE='zensu (security (classify|analyze|suggest-tests|threat-model|add-test|review|validate)|features get) <[^>]*>'
uuid_args() {
  local found
  found="$(printf '%s\n' "$1" | grep -oE -- "$FEATURE_CMD_RE")"
  [ -n "$found" ] && ! printf '%s\n' "$found" | grep -qvE -- ' <feature-uuid>$' && echo PASS || echo FAIL
}
M4_MISSING=""
for c in 'security classify' 'security analyze' 'security suggest-tests' 'security threat-model' 'security add-test' \
  'security review' 'security validate' 'features get'; do
  printf '%s' "$WHOLE" | grep -qF -- "zensu $c <feature-uuid>" || M4_MISSING="$M4_MISSING [$c]"
done
check "M4 every feature-scoped zensu command passes <feature-uuid>, none another placeholder${M4_MISSING:+ (missing:$M4_MISSING)}" "$(all \
  "$(uuid_args "$WHOLE")" \
  "$([ -z "$M4_MISSING" ] && echo PASS || echo FAIL)")"

check "M5 the CLI table lists the Step 1 resolution commands" "$(all \
  "$(has "$CLI_TABLE" '| `zensu products list` | 1 | Find the product whose `feature_key` is')" \
  "$(has "$CLI_TABLE" "| \`zensu features list\` | 1 | Resolve a \`KEY-N\` id or a slug to the feature's UUID")")"

check "M6 zensu security posture takes the product as a positional argument, the only form 0.22.0 accepts, in the skill and in both zensu-plm agent prompts" "$(all \
  "$(has "$STEP7" 'run `zensu security posture <product-id>`')" \
  "$(has "$STEP7" 'there is no `--product` flag on this command')" \
  "$(lacks "$WHOLE" 'zensu security posture --product')" \
  "$(has "$PLM_CLI_TEXT" '`zensu security posture <product-id>` — Product-wide security overview (product id is positional, not `--product`)')" \
  "$(has "$PLM_IDE_TEXT" '`zensu security posture <product-id>` — Product-wide security overview (product id is positional, not `--product`)')" \
  "$(lacks "$PLM_CLI_TEXT" 'zensu security posture --product')" \
  "$(lacks "$PLM_IDE_TEXT" 'zensu security posture --product')")"

check "M7 Step 6 names the review-type flag --type that 0.22.0 has, never --review-type" "$(all \
  "$(has "$STEP6" '- `--type` (optional): manual | automated | external (default: manual)')" \
  "$(lacks "$WHOLE" '--review-type')")"

check "M8 the help pointer names zensu <noun> <verb> --help, since the skill also runs products and features commands" \
  "$(has "$PREREQ" 'run `zensu <noun> <verb> --help` for the full flag set')"

check "M9 Step 7 names where the posture product id comes from, also for a UUID input, and the CLI table lists that read" "$(all \
  "$(has "$STEP7" '`<product-id>` is the product Step 1 resolved; when the user gave a UUID, take it from the `product_id` in `zensu features get <feature-uuid> --json`')" \
  "$(has "$CLI_TABLE" "| \`zensu features get\` | 7 | Read the feature's \`product_id\` for the posture call when the user gave a UUID |")")"

M10_GOOD='Run `zensu security analyze <feature-uuid>`, then `zensu features get <feature-uuid> --json`.'
M10_KEY='Run `zensu security analyze <feature-uuid>`, then `zensu security validate <feature-id>`.'
M10_FEATURE_KEY='Run `zensu security analyze <feature-uuid>`, then `zensu features get <feature-id> --json`.'
M10_NONE='Run `zensu security posture <product-id>` once.'
check "M10 the UUID-argument check passes UUID-only text and fails a KEY-N placeholder on a security or features command, or text without a feature call" "$(all \
  "$(uuid_args "$M10_GOOD")" \
  "$([ "$(uuid_args "$M10_KEY")" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(uuid_args "$M10_FEATURE_KEY")" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(uuid_args "$M10_NONE")" = FAIL ] && echo PASS || echo FAIL)")"

M11_GOOD='`zensu products list --json` → `zensu features list --product <product-id> --json`'
M11_LATE='`zensu features list --product <product-id> --json`, then `zensu products list --json`'
M11_NONE='`zensu features list --product <product-id> --json`'
check "M11 the order check passes products-before-features text and fails a late or a missing products read" "$(all \
  "$(before "$M11_GOOD" 'zensu products list --json' 'zensu features list --product <product-id> --json')" \
  "$([ "$(before "$M11_LATE" 'zensu products list --json' 'zensu features list --product <product-id> --json')" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(before "$M11_NONE" 'zensu products list --json' 'zensu features list --product <product-id> --json')" = FAIL ] && echo PASS || echo FAIL)")"

echo "----"
echo "test-security-review-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
