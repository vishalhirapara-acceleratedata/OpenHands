WITH orders AS (
  SELECT
    order_id,
    amount,
    order_date
  FROM {{ ref('stg_orders') }}
),

final AS (
  -- Grain: one row per order_id
  SELECT
    order_id,
    amount,
    order_date
  FROM orders
)

SELECT * FROM final
