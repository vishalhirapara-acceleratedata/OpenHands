WITH source AS (
  SELECT
    order_id,
    amount,
    order_date
  FROM {{ source('raw', 'fct_orders') }}
)

SELECT
  CAST(order_id AS INTEGER) AS order_id,
  CAST(amount AS DOUBLE) AS amount,
  CAST(order_date AS DATE) AS order_date
FROM source
