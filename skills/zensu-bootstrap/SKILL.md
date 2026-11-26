---
name: zensu-bootstrap
description: Bootstrap a new Zensu product from a vision/plan document through to a fully configured product with features, journeys, security profiles, tiers, and a CLAUDE.md. Use as the greenfield entry point when starting a new project from a plan doc (MVP spec, PRD, idea paper) with no code yet.
---

# /zensu-bootstrap

Bootstrap a new Zensu product from a vision document through to a fully configured product with features, journeys, security profiles, tiers, and a CLAUDE.md.

## When to Use

This is the **greenfield** entry point — a new product captured from a plan/vision doc, before (or independent of) any code.

- Starting a new project from scratch with a plan document (MVP spec, PRD, idea paper)
- Converting an existing product vision into tracked features
- Setting up a complete product in Zensu for the first time

**Brownfield instead?** Code already exists and its features are untracked → use `/zensu-ghost-scan`.

**Hybrid (existing code *and* this plan doc)?** Run `/zensu-ghost-scan` first to import what is built, then create the plan's not-yet-built items as `planned` features — see that skill's Phase 6.

## Prerequisites

- Zensu CLI installed (`curl -fsSL https://zensu.dev/install.sh | sh`) and authenticated (`zensu auth login`)
- `ZENSU_API_KEY` environment variable set
- A product plan or vision document (MVP spec, PRD, or idea paper)

Every command accepts `--json` for machine-readable output; run `zensu <noun> <verb> --help` for the full flag set.

## Workflow

Execute these phases in order. Present results to the user after each phase and wait for confirmation before proceeding.

**Workflow gate (first + last action).** As the VERY FIRST action, run `bash "$(cat "$HOME/.zensu/plugin-root")/hooks/lib/zensu-log.sh" --workflow-begin --tools "create_product,create_product_vision,bootstrap_from_vision,apply_bootstrap,create_feature,add_subfeature,create_tier,set_feature_tiers,create_user_journey,create_journey_step,split_feature,update_feature,deprecate_feature,set_security_classification,update_bootstrap_step,generate_claude_md,generate_threat_model,analyze_feature_security"`. This marks the Zensu product workflow active so the CLI write-gate (`hooks.mcpGate`, default-on) recognizes this skill's `zensu products create` / `zensu products vision-create` / `zensu products bootstrap-apply` / `zensu features create` commands as workflow-driven rather than freelance and does not block them. As the VERY LAST action (after Phase 4, or on early exit), run `bash "$(cat "$HOME/.zensu/plugin-root")/hooks/lib/zensu-log.sh" --workflow-end`.

### Phase 1: Product & Vision Setup

1. Ask the user for their product name, slug, type (public_product|internal_product|hybrid), and the vision/plan document content
2. Run `zensu products create` with name, slug, and product type
3. Run `zensu products vision-create --product <product-id> --content <plan-document> --source kiro`
4. Save the returned product_id and vision_id for subsequent steps

### Phase 2: Feature Extraction & Bootstrap

1. Run `zensu products vision-get <vision-id>` to get the vision content
2. Analyze the vision document and decompose it into components and features following these rules:
   - **Components**: Domain-based boundaries, NOT layer-based. One component per bounded context or domain module. Most products have 3-8 components. Never create "infrastructure", "devops", or "shared" components.
   - **Features**: Vertical slices of user value (INVEST criteria). Do NOT create features for CI/CD, deployment, infrastructure, database setup, monitoring, or scaffolding.
   - **Priority distribution**: ~20% critical, ~30% high, ~30% medium, ~20% low
   - **Security classification**: public (no sensitive data), internal (standard auth), confidential (PII/financial), restricted (health/credentials/regulatory)
   - **Estimated effort**: S (hours-1 day), M (2-3 days), L (1-2 weeks), XL (2+ weeks, consider splitting)
3. Present the decomposition to the user for review
4. Run `zensu products bootstrap-apply <vision-id> --result '<json>'` with the structured JSON containing components and features
5. Report the created entities (component count, feature count, features by priority). Bootstrapped features start at `planned` with **no revision baseline** — there is nothing built yet to capture; a feature gets its v1 revision at implement-time (`/zensu-implement`), or at discovery if `/zensu-ghost-scan` later finds it already built

### Phase 3: Post-Bootstrap Setup (5 Steps)

Execute each step below, presenting results to the user after each.

**Step 1: Review & Refine Features**
- Review the bootstrapped features with the user (`zensu features list --product <product-id> --json`). `zensu products bootstrap-apply` returns counts, not feature IDs, so this list is the source of every `<feature-uuid>` in Phase 3: each entry's `id` is the feature's UUID. Read it again after any change that adds, splits or removes features, before the next feature-scoped command, and skip entries whose `deprecated_at` is set. When the user names a feature by its `KEY-N` id or its slug, match `number` for a `KEY-N` id whose `KEY` is the product's `feature_key` (`zensu products get <product-id> --json`), or `slug` for a slug, and take that entry's `id`. If the `KEY` is another product's, or no entry or more than one matches, ask the user instead of guessing. A feature-scoped command fails with HTTP 400 `invalid feature id` when it gets a `KEY-N` id or a slug instead of the UUID.
- Remove horizontal/implementation features that shouldn't be tracked with `zensu features deprecate <feature-uuid> --reason <reason>`
- Split XL-effort features using `zensu subfeatures add <feature-uuid>` or `zensu features split <feature-uuid>`
- Add missing features with `zensu features create`
- Fix incorrect priorities with `zensu features update <feature-uuid> --priority <low|medium|high|critical>` and incorrect security classifications with `zensu security classify <feature-uuid> --classification <public|internal|confidential|restricted>`
- After completion: run `zensu products bootstrap-step <vision-id> --step 1`

**Step 2: Define User Journeys**
- Re-read `zensu features list --product <product-id> --json` first, since Step 1 may have added, split or removed features: each entry's `id` is the `<feature-uuid>` a journey step links through `--feature`
- Run `zensu journeys suggest --product <product-id>` to get product context for journey suggestions
- Propose 3-5 critical user journeys to the user
- Create approved journeys with `zensu journeys create --product <product-id>` (include title, slug, journey type, priority, persona)
- For each journey, add steps with `zensu journeys step <journey-id> --product <product-id>`:
  - Set step order (1-based sequential) via `--step-order`
  - Link to features via `--feature <feature-uuid>`
  - Set `--interaction-type` (action|navigation|input|validation|output|wait)
  - Mark critical steps with `--critical`
- Run `zensu journeys health --product <product-id> <journey-id>` on each journey to identify weak links
- After completion: run `zensu products bootstrap-step <vision-id> --step 2`

**Step 3: Deepen Security Setup**
- Re-read `zensu features list --product <product-id> --json` first, since Step 1 may have added, split or removed features: each entry's `id` is the `<feature-uuid>` below, and its `security_classification` and `priority` pick the features
- Run `zensu security analyze <feature-uuid>` on all confidential/restricted features
- Run `zensu security suggest-tests <feature-uuid>` on high-risk features to identify needed tests
- Run `zensu security threat-model <feature-uuid>` on the most critical feature for STRIDE analysis
- Present the security posture summary to the user
- After completion: run `zensu products bootstrap-step <vision-id> --step 3`

**Step 4: Set Up Tier Availability (Optional)**
- Ask the user: "Does this product use pricing tiers (e.g. Free/Pro/Enterprise)?"
- If yes:
  1. Ask which tiers they need
  2. Run `zensu tiers create --product <product-id>` for each tier (ascending tier order: 1, 2, 3...)
  3. Run `zensu tiers set-feature <feature-uuid>` for each feature:
     - Critical features: available in all tiers (hard gating)
     - High priority: Pro and above
     - Medium/low: highest tier only
  4. Run `zensu tiers matrix --product <product-id>` to show the complete matrix
- If no: skip directly to Step 5
- After completion: run `zensu products bootstrap-step <vision-id> --step 4` (or `--step 5` if skipping)

**Step 5: Generate CLAUDE.md**
- Run `zensu doc claude-md --product <product-id> --variant full`
- Present the generated CLAUDE.md to the user
- After completion: run `zensu products bootstrap-step <vision-id> --step 5`

### Phase 4: Summary

Present a final summary:
- Product name and type
- Number of components and features created
- Journeys defined and their health scores
- Security posture overview
- Tier configuration (if applicable)
- CLAUDE.md generated

The product is now ready for implementation. Features can be worked on using the `/zensu-implement` skill.

## CLI Commands Used

| Command | Phase | Purpose |
|---------|-------|---------|
| `zensu products create` | 1 | Create the product |
| `zensu products vision-create` | 1 | Store the vision document |
| `zensu products vision-get` | 2 | Get vision content for analysis |
| `zensu products bootstrap-apply` | 2 | Create components and features from decomposition |
| `zensu features list` | 3.1, 3.2, 3.3 | Review bootstrapped features; each entry's `id` is the `<feature-uuid>` the feature-scoped commands take |
| `zensu products get` | 3.1 | Read the product's `feature_key` to check the `KEY` of a `KEY-N` id the user names |
| `zensu features update` | 3.1 | Fix priorities, descriptions |
| `zensu security classify` | 3.1 | Fix security classifications |
| `zensu features deprecate` | 3.1 | Remove features that should not be tracked |
| `zensu subfeatures add` | 3.1 | Split large features |
| `zensu features split` | 3.1 | Split features into children |
| `zensu features create` | 3.1 | Add missing features |
| `zensu journeys suggest` | 3.2 | Get context for journey suggestions |
| `zensu journeys create` | 3.2 | Create journeys |
| `zensu journeys step` | 3.2 | Add steps to journeys |
| `zensu journeys health` | 3.2 | Check journey health |
| `zensu security analyze` | 3.3 | Analyze feature security |
| `zensu security suggest-tests` | 3.3 | Get security test suggestions |
| `zensu security threat-model` | 3.3 | Generate STRIDE threat model |
| `zensu tiers create` | 3.4 | Create pricing tiers |
| `zensu tiers set-feature` | 3.4 | Assign features to tiers |
| `zensu tiers matrix` | 3.4 | Show tier matrix |
| `zensu doc claude-md` | 3.5 | Generate CLAUDE.md template |
| `zensu products bootstrap-step` | 3.x | Track post-bootstrap progress |
