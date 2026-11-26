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

raw_section() {
  awk -v start="$1" -v stop="$2" 'index($0, start) == 1 {p = 1} p && stop != "" && index($0, stop) == 1 {exit} p' "$SKILL_MD"
}
section() { raw_section "$1" "$2" | tr -s '[:space:]' ' '; }
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
STEP5="$(section '### Step 5:' '### Step 6:')"
STEP6="$(section '### Step 6:' '### Step 7:')"
STEP7="$(section '### Step 7:' '### Summary')"
SUMMARY="$(section '### Summary' '## CLI Commands Used')"
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
  "$(has "$STEP6" '- `--type`: `automated` with `--reviewer kiro`')" \
  "$(lacks "$WHOLE" '--review-type')")"

check "M8 the help pointer names zensu <noun> <verb> --help, since the skill also runs products and features commands" \
  "$(has "$PREREQ" 'run `zensu <noun> <verb> --help` for the full flag set')"

check "M9 Step 7 names where the posture product id comes from, also for a UUID input, and the CLI table lists that read for Steps 6 and 7" "$(all \
  "$(has "$STEP7" '`<product-id>` is the product Step 1 resolved; when the user gave a UUID, take it from the `product_id` in `zensu features get <feature-uuid> --json`')" \
  "$(has "$CLI_TABLE" "| \`zensu features get\` | 6, 7 | Read the feature's \`product_id\` for the browser link and the posture call when the user gave a UUID |")")"

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

check "M12 Step 1 sets data sensitivity, the auth type, a boolean, the threat-model status or the pentest status only on file:line evidence or the user's own statement, and leaves out every flag without such evidence" "$(all \
  "$(has "$STEP1" '**Every value you set is a claim the release gate trusts.**')" \
  "$(has "$STEP1" 'Pass `--data-sensitivity`, `--auth-type`, a boolean such as `--auth-required` (spelled `--<flag>=true` or `--<flag>=false`), `--threat-model-status` or `--pentest-status` only when a `file:line` you read in this session shows it, or when the user stated it explicitly, and name that evidence when you present the command.')" \
  "$(has "$STEP1" 'Leave out every flag you have no such evidence for: the CLI sends only the flags you pass, so an omitted flag keeps the recorded value.')" \
  "$(lacks "$STEP1" 'Leave every other flag out')")"

check "M13 Step 1 offers only the classification, threat-model and pentest values the CLI route accepts and hands the others to an admin" "$(all \
  "$(has "$STEP1" '- `--classification`: public | internal | confidential | restricted; pass only a level that keeps or raises the recorded one, and a feature without one counts as `internal`')" \
  "$(has "$STEP1" '- `--threat-model-status`: not-required | pending')" \
  "$(has "$STEP1" '- `--pentest-status`: not-required | pending | failed')" \
  "$(lacks "$WHOLE" 'pending | completed')" \
  "$(lacks "$WHOLE" 'pending | passed')" \
  "$(has "$STEP1" 'Lowering the classification, marking the threat model `completed` and marking a pentest `passed` are decisions for an admin signed in to the Zensu web app, never for this skill: Zensu refuses each of them from `zensu security classify` with a `400`.')" \
  "$(has "$STEP1" "When the evidence or the user calls for one, run no command for it; name it as an open decision for an admin, with its evidence, and hand it on with the feature's browser link (Step 6).")")"

check "M14 Step 5 lists every --last-run-status value 0.22.0 accepts, error included" \
  "$(has "$STEP5" '- `--last-run-status` (optional): passed | failed | skipped | error')"

check "M15 Step 6 leaves the outcome to the user, asked through a plain-text question with explicit options before anything is recorded" "$(all \
  "$(has "$STEP6" "The review status is the user's decision, never yours. Before anything is recorded, present the findings of Steps 2–5")" \
  "$(has "$STEP6" '(score against the required threshold, unmet requirements, threat-model highlights, linked tests and their last run status)')" \
  "$(has "$STEP6" 'ask the user via a plain-text question with explicit options which outcome applies: `rejected`, `conditional` (ask for the conditions) or a clean review that finds nothing blocking.')" \
  "$(has "$STEP6" 'Record a review only for `rejected` or `conditional`, which reject the feature or ask for changes, and record exactly the answer; when the user declines, record nothing.')" \
  "$(before "$STEP6" 'ask the user via a plain-text question with explicit options' 'zensu security review <feature-uuid> --reviewer kiro')" \
  "$(lacks "$WHOLE" 'AskUserQuestion')")"

check "M16 a clean review records nothing: Step 6 never passes approved and hands the approval to an admin with the feature's browser link, and the Summary and the CLI table follow" "$(all \
  "$(has "$STEP6" 'A clean review records nothing. Approving a security review is a decision for an admin signed in to the Zensu web app: Zensu refuses `zensu security review --status approved` with a `400`, so never pass it.')" \
  "$(has "$STEP6" "hand the approval to an admin with the feature's browser link, together with every decision Step 1 left open.")" \
  "$(has "$STEP6" 'When `zensu auth status` reports `https://api.zensu.dev`, the link is `https://app.zensu.dev/products/<product-id>/features/<feature-uuid>?tab=security`')" \
  "$(has "$STEP6" "for another host, ask the user for the address of that instance's web app and give the same path there.")" \
  "$(has "$STEP6" '`<product-id>` is the product Step 1 resolved; when the user gave a UUID, take it from the `product_id` in `zensu features get <feature-uuid> --json`')" \
  "$(has "$STEP6" '- `--status` (required): `rejected` or `conditional`, the one the user chose')" \
  "$(lacks "$WHOLE" 'approved | rejected | conditional')" \
  "$(lacks "$WHOLE" 'approved/rejected/conditional')" \
  "$(has "$SUMMARY" "- Review status (rejected, conditional, waiting for an admin's approval, or not recorded because the user declined)")" \
  "$(has "$SUMMARY" "- Decisions left for an admin, with the feature's browser link")" \
  "$(has "$CLI_TABLE" '| `zensu security review` | 6 | Record a rejected or conditional review |')")"

check "M17 Step 6 records a Kiro-run review as reviewer kiro with type automated and always passes the type, since the CLI defaults to manual" "$(all \
  "$(has "$STEP6" "- \`--reviewer\` (required): \`kiro\` when you did the analysis; the person's own identifier only when they say they reviewed it themselves")" \
  "$(has "$STEP6" "- \`--type\`: \`automated\` with \`--reviewer kiro\`; \`manual\` only for the person's own review and \`external\` only for an outside review the user names. The CLI defaults to \`manual\`, so always pass it.")" \
  "$(has "$STEP6" 'zensu security review <feature-uuid> --reviewer kiro --type automated')" \
  "$(lacks "$WHOLE" 'claude-code')")"

check "M18 Step 6 keeps the findings and the conditions off the command line: the flag list names only the file flags, a heredoc with a quoted delimiter writes each text to a mktemp file, and the write-gate and CLI-floor caveats are stated" "$(all \
  "$(has "$STEP6" '- `--findings-file`: the file with the findings summary; `--conditions-file`: the file with the conditions, only for `conditional`. Both texts are Markdown')" \
  "$(lacks "$STEP6" '- `--findings`:')" \
  "$(has "$STEP6" 'The findings and the conditions are free text and never go into the command line itself')" \
  "$(has "$STEP6" "So write each one to a temporary file through a heredoc whose delimiter is quoted, and pass the file's path")" \
  "$(has "$STEP6" 'with `--findings-file` and `--conditions-file` zensu-cli reads the file itself, up to 256 KiB, and refuses a missing, empty, blank or non-UTF-8 file before it sends anything')" \
  "$(has "$STEP6" 'Replace `<hex>` with eight random hex digits, new for each call and the same on every line that carries it, so no line of the text can end a heredoc early')" \
  "$(has "$STEP6" 'f="$(mktemp)" || exit 1')" \
  "$(has "$STEP6" "cat >| \"\$f\" <<'ZENSU_TEXT_<hex>'")" \
  "$(has "$STEP6" 'For `conditional`, write the conditions to a second file in the same call, widen the one trap to both files, and pass both:')" \
  "$(has "$STEP6" 'The Kiro CLI write-gate also reads the heredoc text as commands, so write no `zensu` command into the findings or conditions; name such an operation in words.')" \
  "$(has "$STEP6" 'Both file flags need zensu-cli 0.22.0: when the CLI rejects either as an unknown flag, record nothing, never fall back to `--findings` or `--conditions`, and ask the user to upgrade.')" \
  "$(lacks "$WHOLE" '--findings "')" \
  "$(lacks "$WHOLE" '--conditions "')")"

zensu() {
  printf '%s\n' "$*" > "$ARGS_OUT"
  while [ "$#" -gt 1 ]; do
    case "$1" in
      --findings-file) printf '%s\n' "$2" > "$PATH_OUT"; cat "$2" > "$TEXT_OUT" ;;
      --conditions-file) printf '%s\n' "$2" > "$CPATH_OUT"; cat "$2" > "$CTEXT_OUT" ;;
    esac
    shift
  done
}
mktemp() { command mktemp "$MKTEMP_DIR/tmp.XXXXXXXX"; }

RECIPE_DIR="$(command mktemp -d)"
trap 'rm -rf "$RECIPE_DIR"' EXIT
mkdir -p "$RECIPE_DIR/tmp" "$RECIPE_DIR/empty-cli" "$RECIPE_DIR/gate-home" "$RECIPE_DIR/gate-state"
RECIPE_UUID='11111111-2222-3333-4444-555555555555'
NL='
'
L1='## Findings'
L2='- `true` and $(true) stay literal'
L3="- \$HOME and \${HOME} stay literal, and so does don't"
L4='- "double quotes" and a back\slash stay too'
FINDINGS_TEXT="$L1$NL$L2$NL$L3$NL$L4"
C1='## Conditions'
C2='- add a `rate-limit` test for $(the login route) first'
C3="- don't log \$TOKEN or \${SECRET}"
CONDITIONS_TEXT="$C1$NL$C2$NL$C3"

recipe() { printf '%s\n' "$1" | awk -v want="$2" '$0 == "```bash" {n++; if (n == want) {p = 1; next}} p && $0 == "```" {exit} p'; }
fill() {
  R="$1" T="$FINDINGS_TEXT" C="$CONDITIONS_TEXT" U="$RECIPE_UUID" awk 'BEGIN {
    n = split(ENVIRON["R"], lines, "\n")
    for (i = 1; i <= n; i++) {
      l = lines[i]
      if (l == "<findings-summary>") { print ENVIRON["T"]; continue }
      if (l == "<conditions>") { print ENVIRON["C"]; continue }
      gsub(/<hex>/, "5e1c0a7f", l)
      gsub(/<feature-uuid>/, ENVIRON["U"], l)
      gsub(/<status-the-user-chose>/, "rejected", l)
      print l
    }
  }'
}
same() { [ -f "$1" ] && [ "$(cat "$1"; printf x)" = "$2${NL}x" ]; }
in_tmp() { case "$1" in "$RECIPE_DIR/tmp/"*) return 0 ;; *) return 1 ;; esac; }
delivers() {
  local mode="$1" f c want
  rm -f "$RECIPE_DIR/args" "$RECIPE_DIR/text" "$RECIPE_DIR/path" "$RECIPE_DIR/ctext" "$RECIPE_DIR/cpath"
  ZENSU_CONFIG_DIR="$RECIPE_DIR/empty-cli" ZENSU_API_URL=http://127.0.0.1:9 ZENSU_NO_UPDATE_CHECK=1 MKTEMP_DIR="$RECIPE_DIR/tmp" \
    ARGS_OUT="$RECIPE_DIR/args" TEXT_OUT="$RECIPE_DIR/text" PATH_OUT="$RECIPE_DIR/path" \
    CTEXT_OUT="$RECIPE_DIR/ctext" CPATH_OUT="$RECIPE_DIR/cpath" \
    bash -c "$(declare -f zensu mktemp)$NL$(fill "$2")" >/dev/null 2>&1 || { echo FAIL; return; }
  [ -f "$RECIPE_DIR/args" ] && [ -f "$RECIPE_DIR/path" ] || { echo FAIL; return; }
  f="$(cat "$RECIPE_DIR/path")"
  same "$RECIPE_DIR/text" "$FINDINGS_TEXT" && in_tmp "$f" && [ ! -e "$f" ] || { echo FAIL; return; }
  want="security review $RECIPE_UUID --reviewer kiro --type automated --status rejected --findings-file $f"
  if [ "$mode" = conditional ]; then
    [ -f "$RECIPE_DIR/cpath" ] || { echo FAIL; return; }
    c="$(cat "$RECIPE_DIR/cpath")"
    same "$RECIPE_DIR/ctext" "$CONDITIONS_TEXT" && in_tmp "$c" && [ ! -e "$c" ] && [ "$c" != "$f" ] || { echo FAIL; return; }
    want="security review $RECIPE_UUID --reviewer kiro --type automated --status conditional --findings-file $f --conditions-file $c"
  fi
  [ "$(cat "$RECIPE_DIR/args")" = "$want" ] || { echo FAIL; return; }
  echo PASS
}

STEP6_RAW="$(raw_section '### Step 6:' '### Step 7:')"
STEP6_RECIPE="$(recipe "$STEP6_RAW" 1)"
STEP6_CONDITIONAL="$(recipe "$STEP6_RAW" 2)"
check "M19 run with a stub zensu and no network, both Step 6 recipes hand findings and conditions with backticks, \$NAME, \$(...), quotes and an apostrophe to the file flags byte-exact, from mktemp files they remove on exit" "$(all \
  "$([ -n "$STEP6_RECIPE" ] && [ -n "$STEP6_CONDITIONAL" ] && echo PASS || echo FAIL)" \
  "$(delivers findings "$STEP6_RECIPE")" \
  "$(delivers conditional "$STEP6_CONDITIONAL")")"

check "M20 Step 6 runs zensu auth status, so the prerequisites exempt zensu auth from the --json promise and the CLI table lists it" "$(all \
  "$(has "$PREREQ" 'Every `zensu` command this skill runs except `zensu auth` accepts `--json` for machine-readable output')" \
  "$(lacks "$WHOLE" 'Every command accepts `--json`')" \
  "$(has "$CLI_TABLE" '| `zensu auth status` | 6 | Read the API host that picks the browser link |')")"

m21_findings() {
  printf '%s\n' "$1" "trap 'rm -f \"\$f\"' EXIT" "cat >| \"\$f\" <<'ZENSU_TEXT_<hex>'" '<findings-summary>' 'ZENSU_TEXT_<hex>' \
    'zensu security review <feature-uuid> --reviewer kiro --type automated \' '  --status <status-the-user-chose> --findings-file "$f"'
}
m21_conditional() {
  printf '%s\n' 'f="$(mktemp)" || exit 1' "trap 'rm -f \"\$f\"' EXIT" 'c="$(mktemp)" || exit 1' "$1" \
    "cat >| \"\$f\" <<'ZENSU_TEXT_<hex>'" '<findings-summary>' 'ZENSU_TEXT_<hex>' \
    "cat >| \"\$c\" <<'ZENSU_TEXT_<hex>'" '<conditions>' 'ZENSU_TEXT_<hex>' \
    'zensu security review <feature-uuid> --reviewer kiro --type automated \' '  --status conditional --findings-file "$f" --conditions-file "$c"'
}
M21_GOOD="$(m21_findings 'f="$(mktemp)" || exit 1')"
M21_UNQUOTED="$(printf '%s\n' "$M21_GOOD" | sed "s/<<'ZENSU_TEXT_<hex>'/<<ZENSU_TEXT_<hex>/")"
M21_NO_TRAP="$(printf '%s\n' "$M21_GOOD" | grep -v '^trap ')"
M21_INLINE="$(printf '%s\n' "$M21_GOOD" | sed 's/--findings-file "\$f"/--findings "$(cat "$f")"/')"
M21_FIXED_PATH="$(m21_findings "f=\"$RECIPE_DIR/fixed.md\"")"
M21_CONDITIONAL="$(m21_conditional "trap 'rm -f \"\$f\" \"\$c\"' EXIT")"
M21_RETRAP="$(m21_conditional "trap 'rm -f \"\$c\"' EXIT")"
check "M21 the recipe check passes quoted-heredoc recipes and fails an unquoted delimiter, a missing trap, findings passed inline, a fixed path, or a second trap that drops the findings file" "$(all \
  "$(delivers findings "$M21_GOOD")" \
  "$([ "$(delivers findings "$M21_UNQUOTED")" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(delivers findings "$M21_NO_TRAP")" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(delivers findings "$M21_INLINE")" = FAIL ] && echo PASS || echo FAIL)" \
  "$([ "$(delivers findings "$M21_FIXED_PATH")" = FAIL ] && echo PASS || echo FAIL)" \
  "$(delivers conditional "$M21_CONDITIONAL")" \
  "$([ "$(delivers conditional "$M21_RETRAP")" = FAIL ] && echo PASS || echo FAIL)")"

GATE_TOOLS="$(grep -oE -- '--workflow-begin --tools "[^"]+"' "$SKILL_MD" | head -1 | sed -E 's/.*--tools "([^"]+)"/\1/')"
gate_rc() {
  CMD="$1" CWD="$RECIPE_DIR" node -e '
    process.stdout.write(JSON.stringify({
      tool_name: "shell",
      session_id: "security-review-recipe",
      cwd: process.env.CWD,
      tool_input: { command: process.env.CMD }
    }));
  ' | HOME="$RECIPE_DIR/gate-home" TDD_STATE_DIR="$RECIPE_DIR/gate-state" env -u ZENSU_PLUGIN_ROOT -u CLAUDE_PROJECT_DIR \
    bash "$PLUGIN_DIR/hooks/kiro/kiro-shim.sh" pre-bash-zensu-gate.sh >/dev/null 2>&1
  echo "$?"
}
window() {
  HOME="$RECIPE_DIR/gate-home" TDD_STATE_DIR="$RECIPE_DIR/gate-state" ZENSU_PLUGIN_ROOT="$PLUGIN_DIR" env -u CLAUDE_PROJECT_DIR \
    bash "$PLUGIN_DIR/hooks/lib/zensu-log.sh" "$@" --session security-review-recipe >/dev/null 2>&1
}
GATE_RECIPE="$(fill "$STEP6_RECIPE")"
GATE_CONDITIONAL="$(fill "$STEP6_CONDITIONAL")"
GATE_BEFORE="$(gate_rc "$GATE_RECIPE")"
window --workflow-begin --tools "$GATE_TOOLS"
GATE_INSIDE="$(gate_rc "$GATE_RECIPE")"
GATE_INSIDE_CONDITIONAL="$(gate_rc "$GATE_CONDITIONAL")"
window --workflow-end
GATE_AFTER="$(gate_rc "$GATE_RECIPE")"
check "M22 the Kiro CLI write-gate denies the Step 6 recipe outside the skill's workflow window and admits both recipes inside it" "$(all \
  "$([ -n "$GATE_TOOLS" ] && command -v node >/dev/null 2>&1 && echo PASS || echo FAIL)" \
  "$([ "$GATE_BEFORE" = 2 ] && echo PASS || echo FAIL)" \
  "$([ "$GATE_INSIDE" = 0 ] && echo PASS || echo FAIL)" \
  "$([ "$GATE_INSIDE_CONDITIONAL" = 0 ] && echo PASS || echo FAIL)" \
  "$([ "$GATE_AFTER" = 2 ] && echo PASS || echo FAIL)")"

PLM_REVIEW='- `zensu security review <id>` — Record a rejected or conditional review the user chose (`--reviewer` and `--status` required: rejected|conditional; always pass `--type`, which defaults to `manual`; findings and conditions only through `--findings-file`/`--conditions-file`)'
PLM_CLASSIFY="it only keeps or raises the classification (none recorded counts as \`internal\`), and every value needs \`file:line\` evidence or the user's explicit statement"
PLM_ADMIN="Lowering a classification, marking a pentest \`passed\` or the threat model \`completed\`, and approving a security review are decisions for an admin signed in to the Zensu web app: Zensu refuses each through the CLI with a \`400\`, and \`/zensu-security-review\` hands them on with the feature's browser link."
PLM_JSON='Every command except `zensu auth` takes `--json` for machine-readable output'
plm_ok() {
  all "$(has "$1" "$PLM_REVIEW")" "$(has "$1" "$PLM_CLASSIFY")" "$(has "$1" "$PLM_ADMIN")" "$(has "$1" "$PLM_JSON")" \
    "$(lacks "$1" 'approved|rejected|conditional')" "$(lacks "$1" 'Every command takes `--json`')"
}
check "M23 both zensu-plm prompts record only a rejected or conditional review through the file flags, keep the classify evidence rule and hand the admin-only decisions on" "$(all \
  "$(plm_ok "$PLM_CLI_TEXT")" \
  "$(plm_ok "$PLM_IDE_TEXT")")"

check "M24 the prerequisites name the zensu-cli 0.22.0 floor the Step 6 file flags need" \
  "$(has "$PREREQ" 'Zensu CLI 0.22.0 or later on `PATH` (`zensu --version`)')"

check "M25 Step 1 reads the recorded classification and data sensitivity before it classifies, so keep-or-raise compares against the recorded level" "$(all \
  "$(has "$STEP1" 'Next, run `zensu security analyze <feature-uuid>` to see the recorded classification and data sensitivity, and ask if changes are needed. Then run `zensu security classify <feature-uuid>` with the relevant flags:')" \
  "$(before "$STEP1" 'zensu security analyze <feature-uuid>' 'zensu security classify <feature-uuid>')" \
  "$(lacks "$STEP1" 'If the feature already has a classification')")"

echo "----"
echo "test-security-review-skill: $PASS PASS / $FAIL FAIL"
[ "$FAIL" -eq 0 ]
