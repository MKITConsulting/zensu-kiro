#!/bin/bash
set -u

PLUGIN_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
GUIDE="$PLUGIN_DIR/docs/documentation-guide.md"
SCOPE_TITLE='Required doc types (the release gate)'

PASS=0; FAIL=0
check() {
  local label="$1" cond="$2"
  if [ "$cond" = "PASS" ]; then echo "  PASS  $label"; PASS=$((PASS+1));
  else echo "  FAIL  $label"; FAIL=$((FAIL+1)); fi
}

if [ ! -f "$GUIDE" ]; then
  check "G1 docs/documentation-guide.md exists" FAIL
  echo "----"
  echo "test-doc-generation-guidance: $PASS PASS / $FAIL FAIL"
  exit 1
fi
check "G1 docs/documentation-guide.md exists" PASS

NORM_GUIDE="$(tr -s '[:space:]' ' ' < "$GUIDE")"

G2_BAD=""
grep -qxF -- "## $SCOPE_TITLE" "$GUIDE" || G2_BAD="$G2_BAD missing:heading"
for row in '| unset (`null`, the default) | `user_facing` | `end_user` |' \
  '| `api` | `api_reference` | `developer` |' \
  '| `internal_only` | `adr` | `internal` |' \
  '| `public_facing` | `user_facing` — **plus** `tutorial` when `estimated_effort` ∈ {L, XL} |'; do
  grep -qF -- "$row" "$GUIDE" || G2_BAD="$G2_BAD missing-row:[$row]"
done
[ -z "$G2_BAD" ] && check "G2 the guide owns the feature_scope -> doc_type table under '## $SCOPE_TITLE'" PASS \
  || check "G2 the guide lost part of the feature_scope -> doc_type table:$G2_BAD" FAIL

G3_BAD=""
for rule in 'So the scope picks the type, not the security classification' \
  'a gate that requires docs reports `documentation must be complete before release`' \
  'Read `feature_scope` and `estimated_effort` from `zensu features get <feature-id>`' \
  'A response without a `feature_scope` field counts as unset: author `user_facing`' \
  'note that the `tutorial` was skipped for lack of an effort signal' \
  'a type the table does not require for the scope never completes the gate' \
  'with a required doc type from the table above' \
  "Every doc type the feature's \`feature_scope\` requires has its doc (Required doc types)."; do
  printf '%s' "$NORM_GUIDE" | grep -qF -- "$rule" || G3_BAD="$G3_BAD missing-rule:[$rule]"
done
[ -z "$G3_BAD" ] && check "G3 the guide keeps the gate text, the unset-scope and unknown-effort rules, and ties its procedure and checklist to the table" PASS \
  || check "G3 the guide lost a rule of the release-gate table:$G3_BAD" FAIL

G4_BAD=""
for advice in 'usually warrants `internal`' 'Pick the type by what the reader needs'; do
  printf '%s' "$NORM_GUIDE" | grep -qF -- "$advice" && G4_BAD="$G4_BAD [$advice]"
done
[ -z "$G4_BAD" ] && check "G4 the guide picks no doc type by security classification or likely reader" PASS \
  || check "G4 the guide still picks a doc type by classification or reader:$G4_BAD" FAIL

SCOPE_ROW_RE='^\| *(unset[^|]*|`(default|api|internal_only|public_facing)`) *\| *`(user_facing|api_reference|adr|tutorial)`'
scope_rows() {
  grep -rnE --include='*.md' --exclude-dir=plans --exclude-dir=validation -- "$SCOPE_ROW_RE" "$@" 2>/dev/null \
    | grep -vF -- "$GUIDE:"
}
G5_ROWS="$(scope_rows "$PLUGIN_DIR/skills" "$PLUGIN_DIR/agents" "$PLUGIN_DIR/docs" "$PLUGIN_DIR/reference" \
  "$PLUGIN_DIR/steering" "$PLUGIN_DIR/POWER.md" "$PLUGIN_DIR/README.md")"
[ -z "$G5_ROWS" ] && check "G5 no skill, agent, steering, reference or other doc keeps its own feature_scope -> doc_type table" PASS \
  || { printf '%s\n' "$G5_ROWS" | sed 's/^/      /'; check "G5 a copy of the feature_scope -> doc_type table outside the guide" FAIL; }

G6_FIX="$(mktemp -d)"
mkdir -p "$G6_FIX/copy" "$G6_FIX/other"
printf '%s\n' '| `api` | `api_reference` | `developer` |' > "$G6_FIX/copy/SKILL.md"
printf '%s\n' '| `default` | `user_facing` | `end_user` |' > "$G6_FIX/copy/rules.md"
printf '%s\n' '| unset (`null`, the default) | `user_facing` | `end_user` |' > "$G6_FIX/copy/steering.md"
printf '%s\n' '| `api` | REST endpoints | `curl` |' '| `api` | status code, response body |' > "$G6_FIX/other/SKILL.md"
G6_COPY="$(scope_rows "$G6_FIX/copy" | wc -l | tr -d ' ')"
G6_OTHER="$(scope_rows "$G6_FIX/other" | wc -l | tr -d ' ')"
rm -rf "$G6_FIX"
[ "$G6_COPY" = 3 ] && [ "$G6_OTHER" = 0 ] && check "G6 the G5 scan flags planted scope table rows and leaves other api tables alone" PASS \
  || check "G6 the G5 scan missed a planted row or flagged another table (copy=$G6_COPY other=$G6_OTHER)" FAIL

echo "----"
echo "test-doc-generation-guidance: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
