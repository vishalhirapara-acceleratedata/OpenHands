# Verify: Small Sales Data Mart

## Certification

verdict: pending — work not yet executed.

## Coverage

| Source | Item | Covered by | Evidence |
| --- | --- | --- | --- |
| `intent.md` success criteria | `dbt build` exits 0 | sandbox run gate | pending |
| `intent.md` success criteria | `sales_mart` one row per `order_id` | `fct_orders` unique test | pending |
| `intent.md` success criteria | Metrics: `total_revenue`, `quantity_sold`, `discount_amount` | mart SQL + schema.yml | pending |
| `intent.md` success criteria | not_null + unique on `order_id` | dbt schema tests | pending |
| `design.md` inventory | `stg_seeds__orders` | sandbox run + tests | pending |
| `design.md` inventory | `stg_seeds__customers` | sandbox run + tests | pending |
| `design.md` inventory | `stg_seeds__products` | sandbox run + tests | pending |
| `design.md` inventory | `fct_orders` | sandbox run + tests | pending |

## Gate results

| Gate | Command | Exit code | Outcome |
| --- | --- | --- | --- |
| Golden replay | `validating-against-baseline` | — | pending |
| Project audit | `dbt_project_evaluator` | — | pending |
| Dev-artifact scan | grep for `dev_mode=True` / `.add_limit()` | — | pending |

## Reviewer verdicts

```json
{
  "verdict": "BLOCK",
  "summary": "Two blocking errors: decision D1 (seeds as raw-layer substitute) clears the ADR promotion bar but has no corresponding ADR file on disk; and the mandatory _git_sha control column is absent from both the Architecture narrative and the mart column inventory.",
  "issues": [
    {
      "severity": "error",
      "message": "Decision D1 — using dbt seeds as the raw-layer substitute (all raw data referenced via {{ ref() }} rather than {{ source() }}) — clears the ADR promotion bar. It is hard to reverse once models are authored against seed refs, it would be surprising to any future contributor who assumes a standard source-system ingestion path, and it sets a project-wide precedent with no existing convention to document it. No docs/adr/NNNN-*.md file with status: decided exists on disk that covers this decision (docs/adr/ contains only .gitkeep). Per domain-context-and-adrs.md, the designing stage must promote this to a decided ADR before the design stop can advance.",
      "location": "design.md § Architecture (D1)"
    },
    {
      "severity": "error",
      "message": "fct_orders specifies only two of the three mandatory dbt control columns: _loaded_at and _dbt_invocation_id are present, but _git_sha is absent from both the Architecture narrative and the mart column inventory. Per runtime-audit-columns.md, all three are non-negotiable for every mart or gold model ('these are non-negotiable for production use'). The design cannot be built to spec without the column definition, its SQL expression, and the required whitespace-guard test.",
      "location": "design.md § Architecture (Mart control columns) and § Inventory → Mart output columns (fct_orders)"
    }
  ],
  "next_step": "1) Author docs/adr/0001-seeds-as-raw-layer-substitute.md with status: decided, capturing the rationale for using dbt seeds in place of {{ source() }} for this project's raw layer. 2) Add _git_sha to fct_orders — column definition (VARCHAR), SQL expression using a whitespace-trimming macro per runtime-audit-columns.md, a not_null test, and a whitespace_free_value_guard test — in both the Architecture narrative and the mart column inventory. Then re-dispatch design-reviewer."
}
```

```json
{
  "verdict": "APPROVE_WITH_WARNINGS",
  "summary": "Both iteration-1 BLOCKs resolved: ADR 0001 is on disk with status:decided and _git_sha appears in Architecture and mart inventory. Two warnings remain: staging model name changes are undocumented as a decision (unlike the D2 note for fct_orders), and the get_git_sha() macro is architecturally specified but absent from the deliverables inventory, risking omission in plan-task derivation.",
  "issues": [
    {
      "severity": "warning",
      "message": "Staging model renames (stg_orders → stg_seeds__orders, stg_customers → stg_seeds__customers, stg_products → stg_seeds__products) are not documented as a named decision in Architecture. The intent explicitly names the staging models without the stg_seeds__ prefix; a reader holding both documents will see three unexplained divergences with no rationale on record. Add a decision note parallel to D2 — e.g. 'D4 — Staging naming: stg_<source>__<entity> convention applied; seeds is the source token' — to match the precedent set by the mart name callout.",
      "location": "design.md § Architecture — no parallel to D2 exists for staging name changes"
    },
    {
      "severity": "warning",
      "message": "The get_git_sha() project macro is fully specified in Architecture (implementation: {{- var('git_sha', env_var('GIT_SHA', 'local')) | trim -}}) but is absent from every inventory section. The macro is a separately authorable file (macros/get_git_sha.sql) whose absence will cause dbt build to fail with an undefined macro error. If plan tasks are derived from the inventory, macro authoring will be silently omitted. Add a Macros Inventory entry or an explicit plan-task callout for this file.",
      "location": "design.md § Inventory — no Macros Inventory section; get_git_sha() macro untracked"
    },
    {
      "severity": "info",
      "message": "The rename of seed column 'quantity' to mart column 'quantity_sold' is implied by the mart inventory note 'From stg_seeds__orders' and the Architecture statement that staging performs rename/cast, but the staging column sets are not documented. It is ambiguous whether the rename occurs in the staging SELECT or the mart SELECT. Documenting staging output columns (even informally) would remove this ambiguity for the implementer.",
      "location": "design.md § Inventory — Mart output columns, quantity_sold row; Seeds table, raw_orders.csv quantity column"
    }
  ]
}
```

```json
{
  "verdict": "BLOCK",
  "summary": "Two errors: (1) the D4 staging source-token choice ('seeds') clears the ADR promotion bar but has no ADR on disk; (2) the mart derivation formulas for discount_amount and total_revenue reference the pre-rename column 'quantity' instead of the staged column 'quantity_sold', making the design unbuildable as written.",
  "issues": [
    {
      "severity": "error",
      "location": "Architecture — D4 / Step 0 ADR-promotion pass",
      "message": "The choice of 'seeds' as the source token in staging model names clears the ADR promotion bar independently of D1."
    },
    {
      "severity": "error",
      "location": "Inventory → Mart output columns (fct_orders) — 'discount_amount' and 'total_revenue' Note column",
      "message": "Both derivation formulas reference 'quantity' (pre-rename) instead of 'quantity_sold' (post-rename in staging). dbt build would fail with a column-not-found error."
    }
  ]
}
```

```json
{
  "verdict": "APPROVE_WITH_WARNINGS",
  "summary": "Both iteration-3 BLOCKs resolved: ADR 0001 extended to cover D4 (on disk, status:decided), and mart formulas corrected to reference quantity_sold. Two warnings remain: not_null tests for _loaded_at and _dbt_invocation_id are unspecified in the design; and the order_date DATE cast is annotated at the mart layer rather than in the staging column mapping, creating layer-boundary ambiguity.",
  "issues": [
    {
      "severity": "warning",
      "message": "_loaded_at and _dbt_invocation_id carry no test annotation. Builder working from design alone will see incomplete test spec.",
      "location": "design.md § Inventory → Mart output columns (_loaded_at and _dbt_invocation_id rows)"
    },
    {
      "severity": "warning",
      "message": "order_date DATE cast annotated at mart layer, not staging layer. Type casts belong in staging; annotation misplacement could produce architecturally incorrect implementation.",
      "location": "design.md § Inventory → Staging output columns and Mart output columns — order_date row"
    }
  ]
}
```

## Approvals
