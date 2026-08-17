-- 15_direct_source_vs_channel.csv
-- Чому source = '(direct)' сидить у Organic Search, Referral і Paid Search.
-- Припущення, яке перевіряється: GA переприписує сесію до попереднього
-- ненульового джерела користувача, тобто channelGrouping — це last NON-DIRECT click.
-- Якщо припущення вірне, такі сесії мають бути переважно повторними.
WITH sess AS (
  SELECT
    fullVisitorId,
    visitId,
    ANY_VALUE(channelGrouping)                            AS channel,
    ANY_VALUE(IFNULL(trafficSource.source, ''))           AS source,
    ANY_VALUE(IFNULL(trafficSource.medium, ''))           AS medium,
    MAX(visitNumber)                                      AS visit_number,
    MAX(IF(trafficSource.isTrueDirect, 1, 0))             AS is_true_direct,
    MAX(IF(trafficSource.referralPath IS NOT NULL, 1, 0)) AS has_referral_path
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
  GROUP BY fullVisitorId, visitId
),
filtered AS (
  SELECT *, IF(source = '(direct)' AND medium = '(none)', 1, 0) AS direct_sourced
  FROM sess
  WHERE channel IS NOT NULL AND channel != '(Other)'
    AND source NOT LIKE '%.google.com'
)
SELECT
  channel,
  COUNT(*)                                                              AS sessions,
  COUNTIF(direct_sourced = 1)                                           AS direct_sourced,
  ROUND(100 * COUNTIF(direct_sourced = 1) / COUNT(*), 1)                AS pct_direct_sourced,
  -- ключове порівняння: повторні візити серед «прихованого direct» vs серед решти каналу
  ROUND(100 * COUNTIF(direct_sourced = 1 AND visit_number > 1)
        / NULLIF(COUNTIF(direct_sourced = 1), 0), 1)                    AS pct_return_direct,
  ROUND(100 * COUNTIF(direct_sourced = 0 AND visit_number > 1)
        / NULLIF(COUNTIF(direct_sourced = 0), 0), 1)                    AS pct_return_rest,
  ROUND(100 * COUNTIF(direct_sourced = 1 AND is_true_direct = 1)
        / NULLIF(COUNTIF(direct_sourced = 1), 0), 1)                    AS pct_true_direct,
  ROUND(100 * COUNTIF(direct_sourced = 1 AND has_referral_path = 1)
        / NULLIF(COUNTIF(direct_sourced = 1), 0), 1)                    AS pct_referral_path
FROM filtered
GROUP BY channel
ORDER BY direct_sourced DESC;


-- 15b_funnel_by_direct_sourced.csv
-- Та сама воронка, розрізана на «сире джерело збігається з каналом» і «приховані direct».
-- Питання: конверсія Referral 6,3% — це властивість каналу чи властивість повернення?
WITH raw_rows AS (
  SELECT
    fullVisitorId,
    visitId,
    channelGrouping                   AS channel,
    IFNULL(trafficSource.source, '')  AS source,
    IFNULL(trafficSource.medium, '')  AS medium,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '2', 1, 0)) FROM UNNEST(hits) h), 0) AS view_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '6', 1, 0)) FROM UNNEST(hits) h), 0) AS purchase_raw
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
),
sess AS (
  SELECT
    fullVisitorId, visitId,
    ANY_VALUE(channel) AS channel,
    ANY_VALUE(source)  AS source,
    ANY_VALUE(medium)  AS medium,
    MAX(view_raw)      AS view_raw,
    MAX(purchase_raw)  AS purchase_raw
  FROM raw_rows
  GROUP BY fullVisitorId, visitId
)
SELECT
  channel,
  IF(source = '(direct)' AND medium = '(none)', 'приховані direct', 'сире джерело') AS bucket,
  COUNT(*)                                                    AS sessions,
  COUNTIF(GREATEST(view_raw, purchase_raw) = 1)               AS viewed_mono,
  COUNTIF(purchase_raw = 1)                                   AS purchases,
  ROUND(100 * COUNTIF(purchase_raw = 1) / COUNT(*), 3)        AS cr_pct
FROM sess
WHERE channel IS NOT NULL AND channel != '(Other)'
  AND source NOT LIKE '%.google.com'
GROUP BY channel, bucket
HAVING sessions >= 100
ORDER BY channel, bucket;


-- 16_referral_path_hidden_direct.csv
-- Що це за 68 860 сесій: referralPath заповнений, source = '(direct)', конверсія 7,5%.
-- Робоче припущення — самореферали з платіжного потоку, тобто розірваний візит,
-- а не окремий канал.
WITH raw_rows AS (
  -- Рівень рядка: hits ще доступний, прапорець рахується тут.
  SELECT
    fullVisitorId,
    visitId,
    channelGrouping                   AS channel,
    IFNULL(trafficSource.source, '')  AS source,
    IFNULL(trafficSource.medium, '')  AS medium,
    trafficSource.referralPath        AS referral_path,
    visitNumber                       AS visit_number,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '6', 1, 0))
            FROM UNNEST(hits) h), 0)  AS purchase_raw
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
),
sess AS (
  -- Рівень сесії: масивів уже немає, лишилися скаляри — MAX працює нормально.
  SELECT
    fullVisitorId,
    visitId,
    ANY_VALUE(channel)       AS channel,
    ANY_VALUE(source)        AS source,
    ANY_VALUE(medium)        AS medium,
    ANY_VALUE(referral_path) AS referral_path,
    MAX(visit_number)        AS visit_number,
    MAX(purchase_raw)        AS purchase_raw
  FROM raw_rows
  GROUP BY fullVisitorId, visitId
)
SELECT
  referral_path,
  COUNT(*)                                                  AS sessions,
  COUNTIF(purchase_raw = 1)                                 AS purchases,
  ROUND(100 * COUNTIF(purchase_raw = 1) / COUNT(*), 2)      AS cr_pct,
  ROUND(100 * COUNTIF(visit_number > 1) / COUNT(*), 1)      AS pct_returning
FROM sess
WHERE channel = 'Referral'
  AND source = '(direct)' AND medium = '(none)'
GROUP BY referral_path
ORDER BY sessions DESC
LIMIT 30;

-- 16b_hidden_direct_landing.csv
-- Перша сторінка сесії. Якщо це /basket.html, /yourinfo.html, /payment.html —
-- це розірваний платіжний потік, і бакет треба схлопувати з попередньою сесією,
-- а не рахувати як канал.
WITH first_hit AS (
  SELECT
    fullVisitorId,
    visitId,
    channelGrouping                  AS channel,
    IFNULL(trafficSource.source, '') AS source,
    IFNULL(trafficSource.medium, '') AS medium,
    (SELECT h.page.pagePath FROM UNNEST(hits) h
      WHERE h.type = 'PAGE' ORDER BY h.hitNumber LIMIT 1) AS landing_page
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
)
SELECT
  landing_page,
  COUNT(*) AS sessions
FROM first_hit
WHERE channel = 'Referral' AND source = '(direct)' AND medium = '(none)'
GROUP BY landing_page
ORDER BY sessions DESC
LIMIT 20;



-- 17_hidden_direct_network.csv
-- Хто ці 67 тисяч сесій із затертим джерелом і конверсією 7,6%.
-- geoNetwork.networkDomain — домен провайдера; для внутрішнього трафіку компанії
-- він часто видає організацію напряму. Порівнюю бакет із рештою датасету.
WITH raw_rows AS (
  SELECT
    fullVisitorId,
    visitId,
    channelGrouping                        AS channel,
    IFNULL(trafficSource.source, '')       AS source,
    IFNULL(trafficSource.medium, '')       AS medium,
    IFNULL(geoNetwork.networkDomain, '')   AS net_domain,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '6', 1, 0))
            FROM UNNEST(hits) h), 0)       AS purchase_raw
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
),
sess AS (
  SELECT
    fullVisitorId, visitId,
    ANY_VALUE(channel)     AS channel,
    ANY_VALUE(source)      AS source,
    ANY_VALUE(medium)      AS medium,
    ANY_VALUE(net_domain)  AS net_domain,
    MAX(purchase_raw)      AS purchase_raw
  FROM raw_rows
  GROUP BY fullVisitorId, visitId
),
tagged AS (
  SELECT *,
    IF(channel = 'Referral' AND source = '(direct)' AND medium = '(none)',
       'бакет', 'решта') AS grp
  FROM sess
  WHERE channel IS NOT NULL AND channel != '(Other)'
    AND source NOT LIKE '%.google.com'
)
SELECT
  grp,
  net_domain,
  COUNT(*)                                               AS sessions,
  COUNTIF(purchase_raw = 1)                              AS purchases,
  ROUND(100 * COUNTIF(purchase_raw = 1) / COUNT(*), 2)   AS cr_pct
FROM tagged
GROUP BY grp, net_domain
QUALIFY ROW_NUMBER() OVER (PARTITION BY grp ORDER BY COUNT(*) DESC) <= 15
ORDER BY grp, sessions DESC;


-- 17b_hidden_direct_concentration.csv
-- Чи тримається бакет на вузькій групі людей. Якщо кілька сотень відвідувачів
-- дають більшість покупок — це не канал, а постійні клієнти або співробітники.
WITH raw_rows AS (
  SELECT
    fullVisitorId,
    visitId,
    channelGrouping                   AS channel,
    IFNULL(trafficSource.source, '')  AS source,
    IFNULL(trafficSource.medium, '')  AS medium,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '6', 1, 0))
            FROM UNNEST(hits) h), 0)  AS purchase_raw
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
),
sess AS (
  SELECT fullVisitorId, visitId,
    ANY_VALUE(channel) AS channel, ANY_VALUE(source) AS source,
    ANY_VALUE(medium) AS medium, MAX(purchase_raw) AS purchase_raw
  FROM raw_rows GROUP BY fullVisitorId, visitId
),
per_visitor AS (
  SELECT
    fullVisitorId,
    IF(channel = 'Referral' AND source = '(direct)' AND medium = '(none)',
       'бакет', 'решта')      AS grp,
    COUNT(*)                  AS sessions,
    COUNTIF(purchase_raw = 1) AS purchases
  FROM sess
  WHERE channel IS NOT NULL AND channel != '(Other)'
    AND source NOT LIKE '%.google.com'
  GROUP BY fullVisitorId, grp
)
SELECT
  grp,
  COUNT(*)                                     AS visitors,
  SUM(sessions)                                AS sessions,
  SUM(purchases)                               AS purchases,
  ROUND(SUM(sessions) / COUNT(*), 2)           AS sessions_per_visitor,
  COUNTIF(purchases >= 1)                      AS buyers,
  COUNTIF(purchases >= 3)                      AS buyers_3plus,
  ROUND(100 * SUM(IF(purchases >= 3, purchases, 0)) / NULLIF(SUM(purchases), 0), 1)
                                               AS pct_purchases_from_3plus
FROM per_visitor
GROUP BY grp;