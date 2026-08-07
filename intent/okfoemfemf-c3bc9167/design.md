# Design: Small Sales Data Mart

## Architecture

**Platform:** DuckDB-local (`$VD_EPHM_DUCKDB_PATH`)

**Source layer:** Three dbt seed files (CSV) supply the raw data — `raw_orders`, `raw_customers`, `raw_products`. Seeds are dbt-managed tables referenced via `{{ ref() }}`; the standard `{{ source() }}` rule does not apply because seeds are not external source tables but dbt's own managed inputs. This is the deliberate raw-layer substitute for this greenfield demo. (D1 — see `docs/adr/0001-seeds-as-raw-layer-substitute.md`)

**Staging layer:** Three `view`-materialised staging models, each 1:1 with one seed table. Light cleanup only: rename, cast, no business logic, no joins.

**Mart layer:** One `table`-materialised fact model, `fct_orders`, grain one row per order. Joins the three staging models directly — no intermediate layer needed given the minimal join count and absence of complex business logic. (D3)

**Model name decision:** User requested `sales_mart`; naming conventions require `fct_` prefix for grain-committed fact models. Name is `fct_orders`. (D2)

**Staging name decision:** Intent named staging models without a source token (`stg_orders`, etc.); naming convention requires `stg_{source}__{entity}`. Source token is `seeds` (the dbt seed layer). Final names: `stg_seeds__orders`, `stg_seeds__customers`, `stg_seeds__products`. (D4 — see `docs/adr/0001-seeds-as-raw-layer-substitute.md`)

**Mart control columns:** `CURRENT_TIMESTAMP AS _loaded_at`, `'{{ invocation_id }}' AS _dbt_invocation_id`, `'{{ get_git_sha() }}' AS _git_sha` — all three required by `runtime-audit-columns.md`. `get_git_sha()` is a project macro: `{{- var('git_sha', env_var('GIT_SHA', 'local')) | trim -}}` with whitespace-trimming delimiters (`{%- -%}`). A `not_null` + whitespace-free guard test is required on `_git_sha`.

**Contract:** `fct_orders` will carry `contract: {enforced: true}` with explicit column types.

## Inventory

### Model Inventory

| # | Model | Layer | Grain | Materialization | Status | Dependencies |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | `stg_seeds__orders` | staging | One row per order (`order_id`) | view | working | seed: `raw_orders` |
| 2 | `stg_seeds__customers` | staging | One row per customer (`customer_id`) | view | working | seed: `raw_customers` |
| 3 | `stg_seeds__products` | staging | One row per product (`product_id`) | view | working | seed: `raw_products` |
| 4 | `fct_orders` | mart | One row per order (`order_id`) | table | working | `stg_seeds__orders`, `stg_seeds__customers`, `stg_seeds__products` |

### Macros Inventory

| Macro file | Macro name | Purpose |
| --- | --- | --- |
| `macros/get_git_sha.sql` | `get_git_sha()` | Emits the git SHA from `var('git_sha', env_var('GIT_SHA', 'local'))` with whitespace trimming; used in all mart control columns |

### Seeds (raw layer — authored as part of this intent)

| Seed file | Columns |
| --- | --- |
| `raw_orders.csv` | `order_id`, `customer_id`, `product_id`, `quantity`, `unit_price`, `discount`, `order_date`, `status` |
| `raw_customers.csv` | `customer_id`, `customer_name`, `email`, `country` |
| `raw_products.csv` | `product_id`, `product_name`, `category` |

### Staging output columns (key renames performed in staging SELECT)

| Model | Seed column → staging column | Notes |
| --- | --- | --- |
| `stg_seeds__orders` | `quantity` → `quantity_sold` | Rename in staging SELECT; mart reads `quantity_sold` |
| `stg_seeds__orders` | `order_date` → `order_date DATE` | **Cast in staging SELECT** (`TRY_CAST(order_date AS DATE)`); mart reads a typed DATE |
| `stg_seeds__orders` | All other columns — pass through as-is | No rename or cast needed |
| `stg_seeds__customers` | All columns — pass through as-is | Already snake_case |
| `stg_seeds__products` | All columns — pass through as-is | Already snake_case |

### Mart output columns (`fct_orders`)

| Column | Type | Note |
| --- | --- | --- |
| `order_id` | VARCHAR | Grain key — `unique` + `not_null` tests |
| `customer_id` | VARCHAR | FK to customer |
| `customer_name` | VARCHAR | Denormalised from `stg_seeds__customers` |
| `product_id` | VARCHAR | FK to product |
| `product_name` | VARCHAR | Denormalised from `stg_seeds__products` |
| `category` | VARCHAR | Product category |
| `quantity_sold` | INTEGER | From `stg_seeds__orders` |
| `unit_price` | DOUBLE | From `stg_seeds__orders` |
| `discount_amount` | DOUBLE | `quantity_sold * unit_price * discount` |
| `total_revenue` | DOUBLE | `quantity_sold * unit_price * (1 - discount)` |
| `order_date` | DATE | Cast performed in `stg_seeds__orders`; mart reads typed DATE |
| `status` | VARCHAR | Order status |
| `_loaded_at` | TIMESTAMP | `CURRENT_TIMESTAMP`; `not_null` test |
| `_dbt_invocation_id` | VARCHAR | `'{{ invocation_id }}'`; `not_null` test |
| `_git_sha` | VARCHAR | `'{{ get_git_sha() }}'` via project macro; `not_null` + whitespace-free guard test |

## Source Mapping / Discovery

**Source:** dbt seeds — no external source system; no ingestion pipeline.

**Probe result:** DuckDB ephemeral sandbox contains no tables (confirmed: new sandbox, no initialization marker). Seeds will be authored as part of this intent's plan tasks.

**Bronze Adequacy verdict: Ready** — seeds are fully controlled synthetic data; schema is defined and owned by this design. No profiling gaps.

## Change Impact

No existing artifacts impacted — fresh build target.

(`models/` directory is empty; no `target/manifest.json`; fresh build shortcut per `change-impact.md`.)

## Approvals
