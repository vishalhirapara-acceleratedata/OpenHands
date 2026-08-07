---
kind: transformation
express: true
---

# Intent: Small Sales Data Mart

## Goal
Build a minimal dbt transformation pipeline that produces a `sales_mart` model, enabling internal analytics on sales orders. Staging models clean and standardise the raw seed data; the mart exposes key sales metrics.

## Source system
dbt seed files (CSV) — synthetic raw sales data (`raw_orders`, `raw_customers`, `raw_products`) seeded into the DuckDB-local sandbox.

## Target
DuckDB-local ephemeral sandbox (`$VD_EPHM_DUCKDB_PATH`); default schema.

## Objects in scope
- `stg_orders` — staging model (cleans raw orders seed)
- `stg_customers` — staging model (cleans raw customers seed)
- `stg_products` — staging model (cleans raw products seed)
- `sales_mart` — mart model (one row per order, key sales metrics)

## Deliverables inventory

Ordered list — one row per deliverable the request names, in request order.

| # | Deliverable | Kind | Notes |
| --- | --- | --- | --- |
| 1 | `stg_orders` | mart/model | Staging layer — normalises raw_orders |
| 2 | `stg_customers` | mart/model | Staging layer — normalises raw_customers |
| 3 | `stg_products` | mart/model | Staging layer — normalises raw_products |
| 4 | `sales_mart` | mart/model | Mart layer — grain: one row per order, keyed by `order_id` |

## Success criteria
- `dbt build` exits 0 against the DuckDB-local sandbox
- `sales_mart` contains one row per `order_id`
- Metrics present: `total_revenue`, `quantity_sold`, `discount_amount`
- dbt schema tests pass: `not_null` and `unique` on `order_id` in `sales_mart`

## Out of scope
- Orchestration schedule
- MetricFlow / semantic model
- Customer or product dimension marts
- Intermediate layer (complexity does not warrant one)

## Open questions
- Consumers: take-it-as-is — internal analytics team
- SLAs / freshness: take-it-as-is — none; on-demand refresh

## Approvals
- [x] User approved intent — 2026-08-07 11:31 (UTC) ("Go ahead")
