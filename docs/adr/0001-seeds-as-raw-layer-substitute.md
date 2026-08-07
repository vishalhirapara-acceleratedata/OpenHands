---
status: decided
date: 2026-08-07
---

# Use dbt seeds as the raw-layer substitute, with `seeds` as the staging source token

This ADR covers two coupled decisions (D1 + D4 in `design.md`):

**D1 — Raw-layer access pattern:** No upstream ingestion pipeline or source-system connector exists. The raw data layer is supplied by three dbt seed files (`raw_orders.csv`, `raw_customers.csv`, `raw_products.csv`), so all staging models reference their seed tables via `{{ ref() }}` rather than `{{ source() }}`. This clears the ADR promotion bar: once staging models point at seed refs, redirecting them to `{{ source() }}` tables requires an explicit find-and-replace across all staging SQL and YAML; any future contributor trained on source-connected pipelines will be surprised; and it sets a project-wide precedent for the raw-layer access pattern with no existing convention to cover it.

**D4 — Staging source token:** The `model-naming.md` convention requires `stg_{source}__{entity}`. Multiple plausible tokens exist for dbt seed files: `seeds` (matches the dbt layer name), `raw` (matches the CSV filename prefix), `seed` (singular), etc. The chosen token is `seeds`. This also clears the ADR bar: any future staging model over a seed table must use the same token or introduce a silent inconsistency; `model-naming.md` illustrates only external-source tokens (e.g. `salesforce`) and provides no guidance for seed-layer tables; the choice is not obvious from the convention alone.

## Considered Options — D1

- **dbt seeds via `{{ ref() }}`** — chosen. No external source system exists; seeds are the simplest fully-controlled raw input that exercises the staging → mart transformation chain without a live connector. Seeds can be replaced by a real `{{ source() }}` pattern in a future ingestion intent without modifying mart logic.
- **Declare seeds as dbt sources and read via `{{ source() }}`** — not chosen. dbt sources are intended to describe tables loaded by an external or dlt pipeline. Wrapping a seed as a source adds indirection with no technical benefit in a project where the seed IS the raw data, and it misrepresents the ingestion model.
- **Skip staging and read seeds directly in the mart** — not chosen. Bypasses the medallion staging contract; staging provides the rename/cast layer that keeps the mart independent of seed column naming.

## Considered Options — D4

- **`seeds`** — chosen. Directly names the dbt layer supplying the data; unambiguous to any dbt practitioner; consistent with the intent to signal the access pattern at a glance.
- **`raw`** — not chosen. Mirrors the CSV filename prefix (`raw_orders`, etc.) but is overly generic and conflicts with the domain-standard `src_` / `raw_` prefix used for dlt bronze landing tables in source-connected projects, which would cause confusion when an ingestion pipeline is added.
- **`seed`** (singular) — not chosen. Less clear than `seeds`; singular/plural inconsistency with the dbt concept name.

## Consequences

- All staging models in this project: (a) read from seed tables via `{{ ref('raw_<entity>') }}`, not `{{ source() }}`; and (b) are named `stg_seeds__<entity>`.
- If a future ingestion intent adds a real source-system pipeline for the same entities, staging models must be updated to `{{ source() }}`, renamed to `stg_<source_system>__<entity>`, and the seeds retired. That transition is a separate product build and will reverse this ADR.
- `dbt_project_evaluator` may flag staging models that lack a corresponding `sources.yml` entry — this must be acknowledged or suppressed in evaluator config until an ingestion pipeline is added.
