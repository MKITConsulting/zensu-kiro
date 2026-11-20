#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL_MD="$PLUGIN_DIR/skills/zensu-implement/SKILL.md"
INSTALL_SH="$PLUGIN_DIR/install.sh"
SCOPE_TITLE='Required doc types (the release gate)'
REFUSAL='previous revision must be released or superseded before creating a new one'

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$SKILL_MD" ]; then
  check "M1 skills/zensu-implement/SKILL.md exists" FAIL
  echo "----"
  echo "test-implement-skill: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "M1 skills/zensu-implement/SKILL.md exists" PASS

section() {
  awk -v start="$1" -v stop="$2" 'index($0, start) == 1 {p = 1} p && index($0, stop) == 1 {exit} p' "$SKILL_MD" \
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

STEP1="$(section '### Step 1:' '### Step 2:')"
STEP6="$(section '### Step 6:' '### Step 7:')"
STEP7="$(section '### Step 7:' '### Step 8:')"
SUMMARY="$(section '### Summary' '## Important Notes')"
CLI_TABLE="$(section '## CLI Commands Used' '## Agents & Skills Used')"

check "M2 Step 1's feature read names the feature_scope and estimated_effort Step 6 picks the doc type from" \
  "$(has "$STEP1" '`feature_scope` and `estimated_effort` that Step 6 picks the doc type from')"

check "M3 Step 6 reads the guide under the plugin root, where install.sh ships it, not from the project" "$(all \
  "$(has "$STEP6" '**Read `docs/documentation-guide.md` under the plugin root** (the directory named in `~/.zensu/plugin-root`, normally `~/.kiro/zensu`;')" \
  "$(has "$STEP6" "the plugin's guide, not a file of this project) first, then follow it.")" \
  "$(grep -qF -- 'install_file "$SRC/docs/documentation-guide.md" "$ZENSU_HOME/docs/documentation-guide.md"' "$INSTALL_SH" && echo PASS || echo FAIL)")"

check "M4 Step 6 takes the required doc type(s) and audience from the guide's '$SCOPE_TITLE' table, once per type" "$(all \
  "$(has "$STEP6" "The table under \"$SCOPE_TITLE\" in that guide maps the \`feature_scope\` and \`estimated_effort\`")" \
  "$(has "$STEP6" 'a feature with an unset scope needs `user_facing`, even a confidential backend feature')" \
  "$(has "$STEP6" 'Run the items below once per required type, with that type as every `<type>` and `--doc-type`')" \
  "$(has "$STEP6" '`--doc-type` (required): the required type this pass documents')" \
  "$(has "$STEP6" "\`--audience\` (optional): end_user | developer | admin | internal; pass the audience the guide's table gives the type")" \
  "$(before "$STEP6" "The table under \"$SCOPE_TITLE\"" '1. Run `zensu doc gen-context <feature-id> --doc-type <type>`')")"

check "M5 Step 6 keeps its code-grounded recipe and its link-only rule" "$(all \
  "$(has "$STEP6" '1. Run `zensu doc gen-context <feature-id> --doc-type <type>` for the context *map*')" \
  "$(has "$STEP6" '**Read the real source files it names**')" \
  "$(has "$STEP6" 'that metadata dump is the exact failure this step prevents')" \
  "$(has "$STEP6" 'Publish with `zensu wiki create --product <product-id> --title <title> --content <markdown>`')" \
  "$(has "$STEP6" 'Then register the doc with `zensu link docs <feature-id>`')" \
  "$(has "$STEP6" 'Run `zensu link docs` alone (no wiki page) only for docs that already live in the repo or at an external URL.')")"

check "M6 Step 6 reads docs_complete after linking and never reports open docs as complete" "$(all \
  "$(has "$STEP6" 'read `docs_complete` from `zensu features get <feature-id>`')" \
  "$(has "$STEP6" 'report the docs as open, never as complete')" \
  "$(before "$STEP6" 'zensu link docs <feature-id>' 'read `docs_complete` from')")"

check "M7 Step 7 states the backend's one-open-revision rule with its refusal text" "$(all \
  "$(has "$STEP7" "it refuses a new one with HTTP 400 \`$REFUSAL\`")" \
  "$(has "$STEP7" 'A new top-level feature starts with an open `v1`')")"

check "M8 Step 7 calls a revision open when active_revision_id is set and stage is neither shipped nor superseded" \
  "$(has "$STEP7" '**A revision is open** when `active_revision_id` is set and `stage` is neither `shipped` nor `superseded`')"

check "M9 Step 7 reads the feature before it runs zensu features revision" "$(all \
  "$(has "$STEP7" 'Re-read the feature with `zensu features get <feature-id>` and take `active_revision_id` and `stage` from it')" \
  "$(before "$STEP7" 'zensu features get <feature-id>' 'zensu features revision <feature-id>')")"

check "M10 Step 7 creates nothing for an open revision and reports which one holds the work" "$(all \
  "$(has "$STEP7" 'Create nothing: this work belongs to that revision')" \
  "$(has "$STEP7" '(stage `<stage>`) holds this work; no new revision created')")"

check "M11 Step 7 creates a revision only when none is open and answers the refusal without a retry" "$(all \
  "$(has "$STEP7" '**No revision is open** (`stage` is `shipped` or `superseded`, or `active_revision_id` is null): run `zensu features revision <feature-id>`')" \
  "$(has "$STEP7" "If it still answers \`$REFUSAL\`, a revision opened in the meantime: report it as in item 2 and do not retry")")"

check "M12 Step 7 keeps the zensu features revision flag list" "$(all \
  "$(has "$STEP7" 'The flags of `zensu features revision`:')" \
  "$(has "$STEP7" '`--scope-summary` (required): Brief summary of what was implemented')" \
  "$(has "$STEP7" '`--estimated-effort` (optional): S | M | L | XL')" \
  "$(has "$STEP7" '`--created-by` (optional): identifier for who created the revision')")"

check "M13 the summary and the CLI table report the docs gate and both revision outcomes" "$(all \
  "$(has "$SUMMARY" 'Documentation linked (doc type(s) and whether `docs_complete` is `true`)')" \
  "$(has "$SUMMARY" 'Revision: the one created (version number), or the open revision this work belongs to (id and stage)')" \
  "$(has "$CLI_TABLE" '| `zensu features get` | 1, 6, 7 |')" \
  "$(has "$CLI_TABLE" '| `zensu features revision` | 7 | Create a feature revision when none is open |')")"

M14_GOOD='1. Re-read with `zensu features get <feature-id>`. 3. Run `zensu features revision <feature-id>`.'
M14_LATE='Run `zensu features revision <feature-id>`, then check `zensu features get <feature-id>`.'
M14_NONE='Run `zensu features revision <feature-id>`.'
check "M14 the order check passes the read-first text and fails a late or a missing read" "$(all \
  "$(before "$M14_GOOD" 'zensu features get <feature-id>' 'zensu features revision <feature-id>')" \
  "$([ "$(before "$M14_LATE" 'zensu features get <feature-id>' 'zensu features revision <feature-id>')" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(before "$M14_NONE" 'zensu features get <feature-id>' 'zensu features revision <feature-id>')" = FAIL ] && echo PASS || echo FAIL)")"

echo "----"
echo "test-implement-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
