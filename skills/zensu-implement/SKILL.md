---
name: zensu-implement
description: Implement a tracked Zensu feature end-to-end — load its feature context and security profile, run disciplined RED-GREEN TDD via the /zensu-tdd skill in the main thread, then link all artifacts (tests, source, docs) and create a revision. Use to start, resume, or complete implementation of a tracked feature.
---

# /zensu-implement

Implement a tracked Zensu feature end-to-end. Loads feature context and security profile, then runs disciplined implementation via the **`/zensu-tdd` skill** in the main thread (strict RED-GREEN TDD, PreToolUse phase-gate, guaranteed code-review chain). After TDD completes, links all artifacts and creates a revision.

## When to Use

- Starting implementation of a planned feature
- Resuming work on an in-progress feature
- Completing a feature with proper artifact linking

## Prerequisites

- Zensu CLI installed (`curl -fsSL https://zensu.dev/install.sh | sh`) and authenticated (`zensu auth login`)
- `ZENSU_API_KEY` environment variable set
- A feature ID to implement. The user may name it as a `KEY-N` id (e.g. `ZEN-42`), a slug or a UUID, but the `zensu` commands below take the feature's UUID, written `<feature-uuid>`: a `KEY-N` id or a slug fails with HTTP 400 `invalid feature id`. Step 1 resolves the ID first.

Every command accepts `--json` for machine-readable output; run `zensu <noun> <verb> --help` for the full flag set.

## Workflow

**Workflow gate (first + last action).** As the VERY FIRST action, run `bash "$(cat "$HOME/.zensu/plugin-root")/hooks/lib/zensu-log.sh" --workflow-begin --tools "analyze_feature_security,link_test,link_source_files,bulk_link_source_files,link_docs,create_wiki_page,create_revision,update_feature"`. This marks the Zensu product workflow active so the CLI write-gate (`hooks.mcpGate`, default-on) recognizes this skill's `zensu link test` / `zensu link source` / `zensu link docs` / `zensu features revision` commands as workflow-driven rather than freelance and does not block them. As the VERY LAST action (after Step 8, or on early exit), run `bash "$(cat "$HOME/.zensu/plugin-root")/hooks/lib/zensu-log.sh" --workflow-end`.

### Step 1: Load Feature Context

1. Ask the user for the feature ID. If it is not a UUID, resolve it before the first feature call: `zensu products list --json` → the product whose `feature_key` matches the `KEY` prefix (a slug has none: ask the user which product it belongs to) → `zensu features list --product <product-id> --json`, then match `number` for a `KEY-N` id or `slug` for a slug. The matching entry's `id` is the `<feature-uuid>` every later step passes. If no entry or more than one matches, ask the user instead of guessing.
2. Run `zensu features get <feature-uuid> --json` to load the full feature details (title, description, status, priority, product, component, security classification). The JSON response includes the `product_id` and `component_id` (when set) that Step 5 needs, and the `feature_scope` and `estimated_effort` that Step 6 picks the doc type from.
3. Run `zensu security analyze <feature-uuid>` to load the security context (classification, data sensitivity, OWASP tags, compliance requirements, score)
4. Run `zensu mocks list <feature-uuid>` to discover per-feature UI mocks. For each **HTML** mock, pull its markup with `zensu mocks get <feature-uuid> <mock-id> --raw` and keep it as the visual/structural target the implementation must match. For **image** mocks, note their titles and that a visual reference exists (the raw bytes are not actionable as text). If no mocks are returned, this feature has none — continue normally; mocks are optional context, never a blocker.
5. Run `zensu design context <product-id>` to load the product/component design system (Design.md guidance + shared CSS + image-asset references), taking `<product-id>` from the `product_id` in Step 2's JSON output; when that response also carries a `component_id`, add `--component <component-id>`. The implementation must conform to this design system. If the product has no design context, continue normally; the design system is optional context, never a blocker.
6. Read and follow [Load and hydrate feature context](references/knowledge-context.md) before planning. Reuse a supplied automatic package for this feature and task; otherwise check `zensu knowledge context-pack --help`, load `zensu knowledge context-pack <feature-ref> --json --agent kiro`, retain the returned `load_id`, inspect truncation, and hydrate relevant real items with `zensu knowledge get <item-id> --json --context-load <load-id>`. Supplement with `zensu knowledge search --query "<feature title + key terms>" --json`; file references require actual reads from the authorized checkout.
7. Present a summary to the user:
   - Feature title and description
   - Current status and priority
   - Security classification and constraints
   - Any security requirements that must be addressed during implementation
   - Available UI mocks (HTML markup loaded, image titles noted) and whether a product/component design system is present

### Step 2: Implementation Planning

Based on the feature context and security profile, help the user plan the implementation:
- Identify files to create or modify
- Note security constraints from the classification (e.g., input validation required, audit logging needed)
- Consider the OWASP tags and compliance requirements
- Outline the implementation approach
- When mocks were loaded in Step 1, the implementation MUST match them visually and structurally: reproduce the HTML mock's layout, structure, and component hierarchy, and treat image-mock titles as the target visual. When a design system was loaded, the implementation MUST conform to it — reuse the shared CSS and follow the Design.md guidance instead of inventing new styles. When neither is present, proceed normally; these are optional context, never a hard blocker.

If the feature's security classification is confidential or restricted, emphasize:
- Input validation on all user inputs
- Proper authentication and authorization checks
- Data encryption requirements
- Audit logging for sensitive operations

### Step 3: Implement via the /zensu-tdd skill

Invoke the **`/zensu-tdd` skill** (slash invocation) with a feature specification built from Steps 1-2 as the input. Include the feature title, description, component, security classification, security constraints from Step 1, the context evidence summary (contents read, excerpt/metadata only, unresolved sources), and the implementation plan from Step 2. End the spec with: "Reference this feature as [KEY-N] (the feature's actual id, e.g. [ZEN-42]) in all commit messages." You run the TDD workflow yourself in THIS main thread — do not spawn a subagent.

If the TDD workflow cannot proceed or all steps are blocked, continue manually from Step 4.

The /zensu-tdd workflow will:
- Split the work into atomic steps and classify each (Feature / Refactor / Bug-fix / Integration)
- Create a plan document in `.zensu/plans/`
- Execute strict RED-GREEN TDD cycles in-thread, enforced by the PreToolUse phase-gate (or direct vanilla implementation when `hooks.tddImplementation` is `false` — the skill branches itself at `--tdd-begin`)
- Run a completeness audit at the end (build, coverage, mtime, precondition drift)
- Provide a progress log at `.zensu/logs/`

At the end of the workflow (Phase 6) it marks implementation complete and spawns `@zensu-code-reviewer` for the 5-perspective review. The `Stop` hook (`stop-chain-enforcer.sh`) guarantees the review chain runs, and `post-review-tdd-delegate.sh` routes any findings back for in-thread fixing until PASS or max rounds.

**For trivial changes** (single-line fix, config change, migration-only): Skip the /zensu-tdd skill and implement directly, then continue with Step 4.

### Step 4: Link Tests

For each test file written (by the /zensu-tdd workflow or manually), run `zensu link test <feature-uuid>` with:
- `--test-type` (required): unit | integration | e2e | security | performance | accessibility
- `--file` (required): Path to the test file
- `--function` (optional): Specific test function
- `--last-run-status` (optional): passed | failed | skipped

### Step 5: Link Source Files

Run `zensu link source <feature-uuid>` to map implementation files to the feature. Pass each file with a repeatable `--file` flag in the form `path[:type[:language[:linecount]]]` (type: source | test | config | migration | docs | generated | other). For cross-feature mapping, run `zensu link source` once per target feature, with that feature's UUID resolved as in Step 1.

### Step 6: Documentation

Documentation must be **code-grounded** — written from the real source you just
implemented, not a restatement of the feature record.
**Read `docs/documentation-guide.md` under the plugin root** (the directory named in
`~/.zensu/plugin-root`, normally `~/.kiro/zensu`; the plugin's guide, not a file of this
project) first, then follow it.

**The feature's scope picks the doc type.** The table under "Required doc types (the
release gate)" in that guide maps the `feature_scope` and `estimated_effort` of Step 1's
`zensu features get` output to the required `doc_type`(s) and their audience. Only a
required type completes the docs gate: a feature with an unset scope needs `user_facing`,
even a confidential backend feature, and for it an `api_reference` doc alone leaves
`documentation must be complete before release` in place. Run the items below once per
required type, with that type as every `<type>` and `--doc-type`:

1. Run `zensu doc gen-context <feature-uuid> --doc-type <type>` for the context *map*
   (source-file paths, symbols, security posture), not the source.
2. **Read the real source files it names** (the files linked in Step 5). The map
   is not the territory.
3. Author Markdown grounded in real signatures, endpoints, and behavior, matched
   to the doc type's focus and audience. Do NOT condense the context metadata
   into `## Purpose / ## Source files / ## Security / ## Notes` sections — that
   metadata dump is the exact failure this step prevents.
4. Publish with `zensu wiki create --product <product-id> --title <title> --content <markdown>`
   (plus `--entity-type`, `--entity-id`, `--doc-type`, `--audience`).

Then register the doc with `zensu link docs <feature-uuid>` (updates the feature's docs score):
- `--doc-type` (required): the required type this pass documents, one of user_facing | api_reference | tutorial | adr | internal | release_notes | migration_guide | overview
- `--title` (optional): Document title
- `--file` (optional): Path to the doc file
- `--external-url` (optional): External URL
- `--audience` (optional): end_user | developer | admin | internal; pass the audience the guide's table gives the type
- `--publication-status` (optional): draft | published | archived

Run `zensu link docs` alone (no wiki page) only for docs that already live in the repo
or at an external URL.

After the last required type, read `docs_complete` from `zensu features get <feature-uuid>`.
When it is not `true`, compare the doc types linked so far with the guide's table and
author the missing one; if every required type is linked and it is still not `true`,
report the docs as open, never as complete.

### Step 7: Create Revision

Zensu keeps one open revision per feature: while the latest revision is neither shipped
nor superseded, it refuses a new one with HTTP 400 `previous revision must be released or
superseded before creating a new one`. A new top-level feature starts with an open `v1`,
so a first implementation belongs to the revision that is already open. Check before you
create:

1. Re-read the feature with `zensu features get <feature-uuid>` and take
   `active_revision_id` and `stage` from it.
2. **A revision is open** when `active_revision_id` is set and `stage` is neither
   `shipped` nor `superseded`. Create nothing: this work belongs to that revision, which
   ships when the feature is released. Report "Revision: open revision
   `<active_revision_id>` (stage `<stage>`) holds this work; no new revision created".
3. **No revision is open** (`stage` is `shipped` or `superseded`, or `active_revision_id`
   is null): run `zensu features revision <feature-uuid>` to version the implementation.
   If it still answers `previous revision must be released or superseded before creating
   a new one`, a revision opened in the meantime: report it as in item 2 and do not
   retry.

The flags of `zensu features revision`:
- `--scope-summary` (required): Brief summary of what was implemented
- `--scope-details` (optional): Detailed scope description
- `--estimated-effort` (optional): S | M | L | XL
- `--coverage-target` (optional): Target coverage percentage (0-100)
- `--docs-required` (optional): Whether docs are required for this revision
- `--created-by` (optional): identifier for who created the revision

### Step 8: Validate

Run `zensu security validate <feature-uuid>` to check if the implementation meets all security requirements for release.

Present the validation results:
- Security score
- Release gate status (pass/fail)
- Any remaining violations to address

### Summary

Present a completion summary:
- Feature title and what was implemented
- Files created/modified (source files linked)
- Tests written and linked (with pass/fail status)
- Documentation linked (doc type(s) and whether `docs_complete` is `true`)
- Revision: the one created (version number), or the open revision this work belongs to (id and stage)
- Security validation status
- TDD report: steps completed, attempts, blocked steps (if any)

## Important Notes

- `zensu features update` does NOT change status. Status transitions (planned -> in-progress -> testing -> released) go through `zensu features status <feature-uuid> <new-status>`.
- Always reference the feature ID in commit messages: `feat(component): description [KEY-N]`
- Security classification should be set BEFORE implementation (use `/zensu-security-review` if not yet set)
- The /zensu-tdd workflow creates a plan at `.zensu/plans/{timestamp}_tdd-{feature-slug}.md` and a progress log at `${CLAUDE_PROJECT_DIR:-.}/.zensu/logs/{timestamp}_tdd-{feature-slug}.log`

## CLI Commands Used

| Command | Step | Purpose |
|---------|------|---------|
| `zensu products list` | 1 | Find the product whose `feature_key` is a `KEY-N` id's `KEY` prefix |
| `zensu features list` | 1 | Resolve a `KEY-N` id or a slug to the feature's UUID (`number` / `slug` match) |
| `zensu features get` | 1, 6, 7 | Load feature details; confirm `docs_complete` after linking; read the active revision's `stage` before creating one |
| `zensu security analyze` | 1 | Load security context |
| `zensu mocks list` | 1 | Discover per-feature UI mocks (HTML + image) |
| `zensu mocks get` | 1 | Pull an HTML mock's raw markup to match (`--raw`) |
| `zensu design context` | 1 | Load the product/component design system (Design.md + shared CSS) |
| `zensu knowledge context-pack` / `zensu knowledge get` / `zensu knowledge search --json` | 1 | Load linked context, hydrate relevant content, supplement with passages |
| `zensu link test` | 4 | Link test files |
| `zensu link source` | 5 | Map source files to feature (bulk via repeated `--file`) |
| `zensu doc gen-context` | 6 | Get the context map to read source before writing docs |
| `zensu wiki create` | 6 | Publish authored markdown to the wiki |
| `zensu link docs` | 6 | Register the doc; updates docs score |
| `zensu features revision` | 7 | Create a feature revision when none is open |
| `zensu security validate` | 8 | Check release readiness |

## Agents & Skills Used

| Component | Type | Step | Purpose |
|-----------|------|------|---------|
| `/zensu-tdd` | skill (main thread) | Step 3 | Strict RED-GREEN TDD, phase-gated, guaranteed review chain |
| `zensu-code-reviewer` | subagent | Step 3 (Phase 6) | 5-perspective code review + auto-fix routing |
