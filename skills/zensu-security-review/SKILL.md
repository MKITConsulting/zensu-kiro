---
name: zensu-security-review
description: Run a comprehensive security review for a Zensu feature, guiding through classification, security-state analysis, security testing, STRIDE threat modeling, and review completion. Use before releasing a feature, when it handles sensitive data, after scope changes, or when preparing for a security audit.
---

# /zensu-security-review

Run a comprehensive security review for a Zensu feature. Guides through classification, analysis, security testing, threat modeling, and review completion.

## When to Use

- Before releasing a feature to production
- When a feature handles sensitive data (PII, financial, credentials)
- After significant changes to a feature's scope or architecture
- When preparing for a security audit

## Prerequisites

- Zensu CLI 0.22.0 or later on `PATH` (`zensu --version`), installed with `curl -fsSL https://zensu.dev/install.sh | sh` (run it again to upgrade), and authenticated (`zensu auth login`)
- A feature ID to review. The user may name it as a `KEY-N` id (e.g. `ZEN-42`), a slug or a UUID, but every feature-scoped `zensu security` command below takes the feature's UUID, written `<feature-uuid>`: a `KEY-N` id or a slug fails with HTTP 400 `invalid feature id`. Step 1 resolves the ID first.

Every `zensu` command this skill runs except `zensu auth` accepts `--json` for machine-readable output; run `zensu <noun> <verb> --help` for the full flag set.

## Workflow

Execute these steps in order. The classification MUST be set first as all subsequent analysis depends on it.

**Workflow gate (first + last action).** As the VERY FIRST action, run `bash "$(cat "$HOME/.zensu/plugin-root")/hooks/lib/zensu-log.sh" --workflow-begin --tools "set_security_classification,analyze_feature_security,add_security_test,generate_threat_model,complete_security_review"`. This marks the Zensu product workflow active so the CLI write-gate (`hooks.mcpGate`, default-on) recognizes this skill's `zensu security classify` / `zensu security analyze` / `zensu security add-test` / `zensu security threat-model` / `zensu security review` commands as workflow-driven rather than freelance and does not block them. As the VERY LAST action (after the final step, or on early exit), run `bash "$(cat "$HOME/.zensu/plugin-root")/hooks/lib/zensu-log.sh" --workflow-end`.

### Step 1: Set Security Classification

Ask the user for the feature ID. If it is not a UUID, resolve it before the first feature call: `zensu products list --json` → the product whose `feature_key` matches the `KEY` prefix (a slug has none: ask the user which product it belongs to) → `zensu features list --product <product-id> --json`, then match `number` for a `KEY-N` id or `slug` for a slug. The matching entry's `id` is the `<feature-uuid>` every later step passes. If no entry or more than one matches, ask the user instead of guessing.

Next, run `zensu security analyze <feature-uuid>` to see the recorded classification and data sensitivity, and ask if changes are needed. Then run `zensu security classify <feature-uuid>` with the relevant flags:

- `--classification`: public | internal | confidential | restricted; pass only a level that keeps or raises the recorded one, and a feature without one counts as `internal`
- `--data-sensitivity`: none | pii | financial | health | credentials
- `--auth-required` / `--auth-type`: jwt | api-key | oauth2 | none
- `--input-validation`, `--rate-limited`, `--encryption-at-rest`, `--encryption-in-transit`, `--audit-logged` (booleans)
- `--threat-model-status`: not-required | pending
- `--pentest-status`: not-required | pending | failed

**Every value you set is a claim the release gate trusts.** Pass `--data-sensitivity`, `--auth-type`, a boolean such as `--auth-required` (spelled `--<flag>=true` or `--<flag>=false`), `--threat-model-status` or `--pentest-status` only when a `file:line` you read in this session shows it, or when the user stated it explicitly, and name that evidence when you present the command. Leave out every flag you have no such evidence for: the CLI sends only the flags you pass, so an omitted flag keeps the recorded value.

Lowering the classification, marking the threat model `completed` and marking a pentest `passed` are decisions for an admin signed in to the Zensu web app, never for this skill: Zensu refuses each of them from `zensu security classify` with a `400`. When the evidence or the user calls for one, run no command for it; name it as an open decision for an admin, with its evidence, and hand it on with the feature's browser link (Step 6).

### Step 2: Analyze Security State

Run `zensu security analyze <feature-uuid>`. This returns:
- Calculated security score (0-10)
- Requirements matrix based on classification
- Release gate status

Present the results to the user, highlighting current score vs. required threshold, met vs. unmet requirements, and any blocking issues for release.

### Step 3: Suggest Security Tests

Run `zensu security suggest-tests <feature-uuid>`. This returns the security profile, existing tests, OWASP tags, compliance tags, and requirements.

Based on the returned context, recommend specific security tests. Map recommendations to the available test types:
- `auth-bypass` — Authentication bypass attempts
- `injection` — SQL/NoSQL/command injection
- `access-control` — Authorization and access control
- `rate-limit` — Rate limiting verification
- `input-validation` — Input sanitization and validation
- `data-exposure` — Sensitive data exposure checks
- `header-security` — Security headers verification
- `dependency-scan` — Dependency vulnerability scan
- `csrf` — Cross-site request forgery
- `xss` — Cross-site scripting
- `ssrf` — Server-side request forgery

### Step 4: Generate Threat Model

Run `zensu security threat-model <feature-uuid>`. This returns the feature security profile, existing threat model, product type, and requirements.

Generate a STRIDE threat model covering:
- **S**poofing — Identity and authentication threats
- **T**ampering — Data integrity threats
- **R**epudiation — Audit and logging threats
- **I**nformation Disclosure — Data exposure threats
- **D**enial of Service — Availability threats
- **E**levation of Privilege — Authorization threats

Present the threat model to the user with specific mitigations for each identified threat.

### Step 5: Link Security Tests

For each recommended and implemented security test, run `zensu security add-test <feature-uuid>` with:
- `--type` (required): auth-bypass | injection | access-control | rate-limit | input-validation | data-exposure | header-security | dependency-scan | csrf | xss | ssrf
- `--file` (required): Path to the test file
- `--last-run-status` (optional): passed | failed | skipped | error
- `--owasp-id` (optional): OWASP Top 10 ID (e.g. A01:2021)

### Step 6: Record the Security Review

The review status is the user's decision, never yours. Before anything is recorded, present the findings of Steps 2–5 (score against the required threshold, unmet requirements, threat-model highlights, linked tests and their last run status) and ask the user via a plain-text question with explicit options which outcome applies: `rejected`, `conditional` (ask for the conditions) or a clean review that finds nothing blocking. Record a review only for `rejected` or `conditional`, which reject the feature or ask for changes, and record exactly the answer; when the user declines, record nothing.

A clean review records nothing. Approving a security review is a decision for an admin signed in to the Zensu web app: Zensu refuses `zensu security review --status approved` with a `400`, so never pass it. Present the findings instead, and hand the approval to an admin with the feature's browser link, together with every decision Step 1 left open. When `zensu auth status` reports `https://api.zensu.dev`, the link is `https://app.zensu.dev/products/<product-id>/features/<feature-uuid>?tab=security`, the feature's page in the hosted web app, opened on its Security tab; for another host, ask the user for the address of that instance's web app and give the same path there. `<product-id>` is the product Step 1 resolved; when the user gave a UUID, take it from the `product_id` in `zensu features get <feature-uuid> --json`.

The command takes:
- `--reviewer` (required): `kiro` when you did the analysis; the person's own identifier only when they say they reviewed it themselves
- `--status` (required): `rejected` or `conditional`, the one the user chose
- `--type`: `automated` with `--reviewer kiro`; `manual` only for the person's own review and `external` only for an outside review the user names. The CLI defaults to `manual`, so always pass it.
- `--findings-file`: the file with the findings summary; `--conditions-file`: the file with the conditions, only for `conditional`. Both texts are Markdown: Zensu's Security tab renders headings, lists and code, so write structured Markdown, not one unformatted paragraph

The findings and the conditions are free text and never go into the command line itself: inside double quotes the shell runs every backtick span and expands every `$NAME`, and a single quote ends at the first apostrophe. So write each one to a temporary file through a heredoc whose delimiter is quoted, and pass the file's path: with `--findings-file` and `--conditions-file` zensu-cli reads the file itself, up to 256 KiB, and refuses a missing, empty, blank or non-UTF-8 file before it sends anything. Replace `<hex>` with eight random hex digits, new for each call and the same on every line that carries it, so no line of the text can end a heredoc early; `>|` writes even under `noclobber`:

```bash
f="$(mktemp)" || exit 1
trap 'rm -f "$f"' EXIT
cat >| "$f" <<'ZENSU_TEXT_<hex>'
<findings-summary>
ZENSU_TEXT_<hex>
zensu security review <feature-uuid> --reviewer kiro --type automated \
  --status <status-the-user-chose> --findings-file "$f"
```

For `conditional`, write the conditions to a second file in the same call, widen the one trap to both files, and pass both:

```bash
f="$(mktemp)" || exit 1
trap 'rm -f "$f"' EXIT
c="$(mktemp)" || exit 1
trap 'rm -f "$f" "$c"' EXIT
cat >| "$f" <<'ZENSU_TEXT_<hex>'
<findings-summary>
ZENSU_TEXT_<hex>
cat >| "$c" <<'ZENSU_TEXT_<hex>'
<conditions>
ZENSU_TEXT_<hex>
zensu security review <feature-uuid> --reviewer kiro --type automated \
  --status conditional --findings-file "$f" --conditions-file "$c"
```

The Kiro CLI write-gate also reads the heredoc text as commands, so write no `zensu` command into the findings or conditions; name such an operation in words. Both file flags need zensu-cli 0.22.0: when the CLI rejects either as an unknown flag, record nothing, never fall back to `--findings` or `--conditions`, and ask the user to upgrade.

### Step 7: Validate Release Readiness

Run `zensu security validate <feature-uuid>` to check if the feature passes all security requirements for release.

If the validation fails, present the blocking violations and guide the user through resolving them.

Optionally, run `zensu security posture <product-id>` to show the product-wide security overview (the product id is a positional argument — there is no `--product` flag on this command). `<product-id>` is the product Step 1 resolved; when the user gave a UUID, take it from the `product_id` in `zensu features get <feature-uuid> --json`.

### Summary

Present a final summary:
- Security classification and data sensitivity
- Security score (before and after review)
- Threat model highlights
- Security tests linked
- Review status (rejected, conditional, waiting for an admin's approval, or not recorded because the user declined)
- Decisions left for an admin, with the feature's browser link
- Release gate status (pass/fail)

## CLI Commands Used

| Command | Step | Purpose |
|---------|------|---------|
| `zensu products list` | 1 | Find the product whose `feature_key` is a `KEY-N` id's `KEY` prefix |
| `zensu features list` | 1 | Resolve a `KEY-N` id or a slug to the feature's UUID (`number` / `slug` match) |
| `zensu security classify` | 1 | Set security attributes |
| `zensu security analyze` | 1, 2 | Analyze current security state |
| `zensu security suggest-tests` | 3 | Get context for test suggestions |
| `zensu security threat-model` | 4 | Get context for STRIDE model |
| `zensu security add-test` | 5 | Link security tests |
| `zensu security review` | 6 | Record a rejected or conditional review |
| `zensu auth status` | 6 | Read the API host that picks the browser link |
| `zensu features get` | 6, 7 | Read the feature's `product_id` for the browser link and the posture call when the user gave a UUID |
| `zensu security validate` | 7 | Check release gate |
| `zensu security posture` | 7 | Product-wide security overview |
