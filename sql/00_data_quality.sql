-- Перевірки якості даних. bigquery-public-data.google_analytics_sample, 12 місяців.
-- Період: 2016-08-01 — 2017-08-01

-- 01_unknown_channels.csv
-- Скільки сесій без каналу і яка частка direct
SELECT
  COUNT(*)                                                        AS sessions,
  COUNTIF(channelGrouping IS NULL OR channelGrouping = '(Other)') AS unknown_channel,
  COUNTIF(trafficSource.medium IN ('(none)', '(not set)'))        AS medium_none_or_notset,
  COUNTIF(trafficSource.source = '(direct)')                      AS source_direct,
  ROUND(100 * COUNTIF(channelGrouping IS NULL OR channelGrouping = '(Other)')
        / COUNT(*), 2)                                            AS pct_unknown_channel
FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801';

-- 02_session_duplicates.csv
-- Чи справді один рядок = одна сесія
SELECT
  COUNT(*)                                                               AS rows_total,
  COUNT(DISTINCT CONCAT(fullVisitorId, '-', CAST(visitId AS STRING)))    AS distinct_sessions,
  COUNT(DISTINCT fullVisitorId)                                          AS distinct_visitors
FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801';

-- 03_funnel_steps.csv
-- action_type: 2 — перегляд товару, 3 — кошик, 5 — checkout, 6 — покупка
WITH session_steps AS (
  SELECT
    fullVisitorId,
    visitId,
    MAX(IF(h.eCommerceAction.action_type = '2', 1, 0)) AS viewed_product,
    MAX(IF(h.eCommerceAction.action_type = '3', 1, 0)) AS added_to_cart,
    MAX(IF(h.eCommerceAction.action_type = '5', 1, 0)) AS checkout,
    MAX(IF(h.eCommerceAction.action_type = '6', 1, 0)) AS purchased
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`,
       UNNEST(hits) AS h
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
  GROUP BY fullVisitorId, visitId
)
SELECT
  COUNTIF(purchased = 1)                            AS purchase_sessions,
  COUNTIF(purchased = 1 AND viewed_product = 0)     AS purchase_without_view,
  COUNTIF(purchased = 1 AND added_to_cart = 0)      AS purchase_without_cart,
  COUNTIF(purchased = 1 AND checkout = 0)           AS purchase_without_checkout,
  ROUND(100 * COUNTIF(purchased = 1 AND viewed_product = 0)
        / NULLIF(COUNTIF(purchased = 1), 0), 2)     AS pct_purchase_without_view
FROM session_steps;

-- 04_tx_duplicates.csv
-- Дублікати transactionId — зведення
WITH tx AS (
  SELECT
    h.transaction.transactionId                                  AS tx_id,
    CONCAT(fullVisitorId, '-', CAST(visitId AS STRING))          AS session_key
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`,
       UNNEST(hits) AS h
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
    AND h.transaction.transactionId IS NOT NULL
),
per_tx AS (
  SELECT
    tx_id,
    COUNT(*)                     AS hit_rows,
    COUNT(DISTINCT session_key)  AS sessions_per_tx
  FROM tx
  GROUP BY tx_id
)
SELECT
  COUNT(*)                          AS distinct_transaction_ids,
  COUNTIF(hit_rows > 1)             AS ids_in_multiple_hits,
  COUNTIF(sessions_per_tx > 1)      AS ids_in_multiple_sessions
FROM per_tx;

-- 04b_tx_duplicates_examples.csv
-- Приклади дублів — подивитись очима перед тим, як вирішувати
WITH tx AS (
  SELECT
    h.transaction.transactionId                                  AS tx_id,
    CONCAT(fullVisitorId, '-', CAST(visitId AS STRING))          AS session_key,
    h.transaction.transactionRevenue / 1e6                       AS hit_revenue_usd
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`,
       UNNEST(hits) AS h
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
    AND h.transaction.transactionId IS NOT NULL
)
SELECT
  tx_id,
  COUNT(*)                          AS hit_rows,
  COUNT(DISTINCT session_key)       AS sessions_per_tx,
  ROUND(SUM(hit_revenue_usd), 2)    AS revenue_sum_if_naive
FROM tx
GROUP BY tx_id
HAVING hit_rows > 1
ORDER BY hit_rows DESC
LIMIT 20;

-- 05_revenue_distribution.csv
-- transactionRevenue у мікроодиницях — ділити на 1e6
SELECT
  COUNT(*)                                                              AS sessions,
  COUNTIF(totals.transactionRevenue IS NULL)                            AS revenue_null,
  COUNTIF(totals.transactionRevenue = 0)                                AS revenue_zero,
  COUNTIF(totals.transactionRevenue < 0)                                AS revenue_negative,
  ROUND(MIN(totals.transactionRevenue) / 1e6, 2)                        AS min_usd,
  ROUND(APPROX_QUANTILES(totals.transactionRevenue, 100)[OFFSET(50)] / 1e6, 2) AS p50_usd,
  ROUND(APPROX_QUANTILES(totals.transactionRevenue, 100)[OFFSET(95)] / 1e6, 2) AS p95_usd,
  ROUND(APPROX_QUANTILES(totals.transactionRevenue, 100)[OFFSET(99)] / 1e6, 2) AS p99_usd,
  ROUND(MAX(totals.transactionRevenue) / 1e6, 2)                        AS max_usd
FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801';


-- 05b_revenue_source_of_truth.csv
-- Виручка на рівні сесії проти виручки на рівні хіта
SELECT
  ROUND(SUM(totals.transactionRevenue) / 1e6, 2) AS session_level_usd,
  ROUND((SELECT SUM(h.transaction.transactionRevenue)
         FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*` s2,
              UNNEST(s2.hits) AS h
         WHERE s2._TABLE_SUFFIX BETWEEN '20160801' AND '20170801') / 1e6, 2)
                                                 AS hit_level_usd
FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801';

-- 06_null_pageviews.csv
-- Сесії з NULL у totals.pageviews
SELECT
  COUNT(*)                                                                  AS sessions,
  COUNTIF(totals.pageviews IS NULL)                                         AS pageviews_null,
  COUNTIF(totals.hits IS NULL)                                              AS hits_null,
  COUNTIF(totals.pageviews IS NULL AND totals.transactionRevenue IS NOT NULL) AS null_pageviews_with_revenue,
  ROUND(100 * COUNTIF(totals.pageviews IS NULL) / COUNT(*), 3)              AS pct_pageviews_null
FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801';


-- 07_suspicious_sources.csv
-- Кандидати на виключення: джерела з підозріло високою конверсією
SELECT
  trafficSource.source,
  trafficSource.medium,
  COUNT(*)                                      AS sessions,
  COUNTIF(totals.transactions IS NOT NULL)      AS purchase_sessions,
  ROUND(100 * COUNTIF(totals.transactions IS NOT NULL)
        / COUNT(*), 2)                          AS conversion_pct
FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
GROUP BY trafficSource.source, trafficSource.medium
HAVING sessions >= 100
ORDER BY conversion_pct DESC
LIMIT 30;