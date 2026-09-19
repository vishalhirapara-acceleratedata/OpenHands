---
kinds: [orchestration]
---

# Intent: daily_refresh orchestration pipeline

## Classification

| Axis | Value | Rationale |
| --- | --- | --- |
| Action | work | New orchestration artifact requested |
| Kinds | [orchestration] | A new native Orchestration Pipeline that schedules a dlt workload |

## Goal

Automate a daily refresh of data ingested by a single dlt pipeline, running at 06:00 UTC each day, so that downstream consumers have up-to-date data available each morning.

## Source system

A single dlt ingestion pipeline (name not yet specified) that loads data into the domain's DuckDB-local destination.

## Target

Platform: `duckdb_local` (DuckDB local file). The active data platform does not have a native orchestration implementation — Design will recommend `omit` with that reason.

## Deliverables inventory

| # | Deliverable | Kind | Requirement refs | Notes |
| --- | --- | --- | --- | --- |
| 1 | daily_refresh Orchestration Pipeline | orchestration | R-01@1 | Single pipeline invoking one dlt pipeline on a daily schedule |

## Requirements

| ID | Revision | Requirement | Acceptance criteria | Source | Resolution | Status |
| --- | --- | --- | --- | --- | --- | --- |
| R-01 | 1 | A native Orchestration Pipeline named `daily_refresh` is authored to invoke a single dlt ingestion pipeline on a daily schedule at 06:00 UTC. | 1) A committed orchestration item named `daily_refresh` exists in the repository. 2) The item declares a daily schedule at 06:00 UTC. 3) The item references exactly one dlt pipeline as its invoked workload. | User request: "daily_refresh orchestration pipeline"; schedule: user selected 06:00 UTC; workloads: user selected dlt-only, single named pipeline | Open question: specific dlt pipeline name not yet provided | pending |
| R-02 | 1 | The orchestration pipeline's lifecycle action is `create` — no prior orchestration item exists in the repository. | 1) The `orchestration/` directory is either absent or contains no `daily_refresh` item before this intent's work. 2) The committed item is newly created, not a modification of an existing item. | Derived fact: no `orchestration/` directory or items exist in the workspace | derived fact | pending |

## Out of scope

- Authoring or modifying the dlt ingestion pipeline itself (separate ingestion-kind intent).
- Authoring or modifying any dbt transformation models (separate transformation-kind intent).
- Production deployment, schedule activation, or execution — these are customer-owned post-ship activities.

## Open questions

| Question | Blocked work | Take-it-as-is? |
| --- | --- | --- |
| What is the name of the specific dlt pipeline that `daily_refresh` should invoke? | R-01 acceptance criteria 3 (invoked workload reference) | No — the invoked workload is material to the orchestration item's content |

## Design pending

- **Platform limitation**: `duckdb_local` has no native orchestration implementation. Design will recommend `Action: omit` with the reason that the platform does not support native orchestration items. This is a technical constraint, not a business decision.
- **Orchestration target**: Not applicable on `duckdb_local` — no Data Pipeline or Airflow target exists for this platform.

## Change history

No prior revisions. Initial capture.

## Change impact

No downstream artifacts, plans, or tasks exist yet. No impact to assess.

## Approvals

No approvals recorded. Requirement is pending.
