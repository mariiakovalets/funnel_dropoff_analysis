-- sql/02_segments.sql
-- Блок 2. Сегменти: пристрій, новий/повернений, географія, перетин канал × пристрій.
-- bigquery-public-data.google_analytics_sample, 2016-08-01 — 2017-08-01
--
-- Населення аналізу — те саме, що в блоці 1: channelGrouping IS NOT NULL,
-- != '(Other)', source NOT LIKE '%.google.com'. ROLLUP-підсумки в кожному
-- запиті мають збігтися з 879 171 сесією з 13_exclusions_reconciliation.csv —
-- це перевірка, що фільтр застосований правильно, а не новий факт.
-- Ключ поведінкової сесії — fullVisitorId + visitId (рішення №3b, як у блоці 1).

-- 21_funnel_by_device.csv
-- Основний артефакт гіпотези 2. Та сама воронка, що 12_funnel_by_channel.csv,
-- розрізана по device.deviceCategory замість channelGrouping.
-- tablet рахується окремо і в порівняння mobile/desktop не входить (пре-реєстровано),
-- але в таблиці лишається — інакше ROLLUP-підсумок розійдеться з 879 171.
WITH raw_rows AS (
  SELECT
    fullVisitorId,
    visitId,
    channelGrouping                      AS channel,
    IFNULL(trafficSource.source, '')     AS source,
    device.deviceCategory                AS device,

    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '2', 1, 0)) FROM UNNEST(hits) h), 0) AS view_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '3', 1, 0)) FROM UNNEST(hits) h), 0) AS cart_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '5', 1, 0)) FROM UNNEST(hits) h), 0) AS checkout_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '6', 1, 0)) FROM UNNEST(hits) h), 0) AS purchase_raw
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
),
sess AS (
  SELECT
    fullVisitorId,
    visitId,
    ANY_VALUE(channel)   AS channel,
    ANY_VALUE(source)    AS source,
    ANY_VALUE(device)    AS device,
    MAX(view_raw)        AS view_raw,
    MAX(cart_raw)        AS cart_raw,
    MAX(checkout_raw)    AS checkout_raw,
    MAX(purchase_raw)    AS purchase_raw
  FROM raw_rows
  GROUP BY fullVisitorId, visitId
),
filtered AS (
  SELECT * FROM sess
  WHERE channel IS NOT NULL AND channel != '(Other)'
    AND source NOT LIKE '%.google.com'
),
flags AS (
  SELECT
    device,
    GREATEST(view_raw, cart_raw, checkout_raw, purchase_raw) AS view_m,
    GREATEST(cart_raw, checkout_raw, purchase_raw)           AS cart_m,
    GREATEST(checkout_raw, purchase_raw)                     AS checkout_m,
    purchase_raw                                             AS purchase_m,
    view_raw                                                                   AS view_s,
    IF(view_raw = 1 AND cart_raw = 1, 1, 0)                                    AS cart_s,
    IF(view_raw = 1 AND cart_raw = 1 AND checkout_raw = 1, 1, 0)               AS checkout_s,
    IF(view_raw = 1 AND cart_raw = 1 AND checkout_raw = 1 AND purchase_raw = 1, 1, 0) AS purchase_s
  FROM filtered
)
SELECT
  IFNULL(device, 'ВСІ ПРИСТРОЇ') AS device,
  COUNT(*)                       AS sessions,
  COUNTIF(view_m = 1)            AS viewed_mono,
  COUNTIF(cart_m = 1)            AS cart_mono,
  COUNTIF(checkout_m = 1)        AS checkout_mono,
  COUNTIF(purchase_m = 1)        AS purchase_mono,
  COUNTIF(view_s = 1)            AS viewed_strict,
  COUNTIF(cart_s = 1)            AS cart_strict,
  COUNTIF(checkout_s = 1)        AS checkout_strict,
  COUNTIF(purchase_s = 1)        AS purchase_strict
FROM flags
GROUP BY ROLLUP(device)
ORDER BY sessions DESC;


-- 22_monotonic_confound_device.csv
-- Той самий конфаунд, що 14_monotonic_confound.csv в блоці 1, тепер по пристроях.
-- Гіпотеза 2 читає розрив mobile/desktop на кроці «перегляд товару» —
-- якщо монотонність дозаписує цей крок телефонам і комп'ютерам по-різному,
-- частина розриву на вході воронки створена методом, а не поведінкою.
WITH raw_rows AS (
  SELECT
    fullVisitorId,
    visitId,
    channelGrouping                   AS channel,
    IFNULL(trafficSource.source, '')  AS source,
    device.deviceCategory             AS device,
    ARRAY_LENGTH(hits)                AS n_hits,
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
    ANY_VALUE(device)  AS device,
    SUM(n_hits)        AS n_hits,
    MAX(view_raw)      AS view_raw,
    MAX(purchase_raw)  AS purchase_raw
  FROM raw_rows
  GROUP BY fullVisitorId, visitId
),
filtered AS (
  SELECT * FROM sess
  WHERE channel IS NOT NULL AND channel != '(Other)'
    AND source NOT LIKE '%.google.com'
)
SELECT
  IFNULL(device, 'ВСІ ПРИСТРОЇ')                                  AS device,
  COUNTIF(n_hits > 0)                                             AS sessions_with_hits,
  COUNTIF(n_hits > 0 AND view_raw = 0)                            AS no_view_event,
  ROUND(100 * COUNTIF(n_hits > 0 AND view_raw = 0)
        / NULLIF(COUNTIF(n_hits > 0), 0), 2)                      AS pct_no_view,
  COUNTIF(purchase_raw = 1)                                       AS purchase_sessions,
  COUNTIF(purchase_raw = 1 AND view_raw = 0)                      AS buyers_no_view,
  ROUND(100 * COUNTIF(purchase_raw = 1 AND view_raw = 0)
        / NULLIF(COUNTIF(purchase_raw = 1), 0), 2)                AS pct_buyers_no_view
FROM filtered
GROUP BY ROLLUP(device)
ORDER BY sessions_with_hits DESC;


-- 23_funnel_by_returning.csv
-- Воронка нові проти повернені. totals.newVisits — це 1 або NULL, не 0/1,
-- тому IFNULL(...,0) обов'язковий: без нього всі повернені мовчки зникають
-- із групування замість того, щоб потрапити в свій кошик.
WITH raw_rows AS (
  SELECT
    fullVisitorId,
    visitId,
    channelGrouping                      AS channel,
    IFNULL(trafficSource.source, '')     AS source,
    IF(IFNULL(totals.newVisits, 0) = 1, 'новий', 'повернений') AS visitor_type,

    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '2', 1, 0)) FROM UNNEST(hits) h), 0) AS view_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '3', 1, 0)) FROM UNNEST(hits) h), 0) AS cart_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '5', 1, 0)) FROM UNNEST(hits) h), 0) AS checkout_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '6', 1, 0)) FROM UNNEST(hits) h), 0) AS purchase_raw
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
),
sess AS (
  SELECT
    fullVisitorId, visitId,
    ANY_VALUE(channel)      AS channel,
    ANY_VALUE(source)       AS source,
    ANY_VALUE(visitor_type) AS visitor_type,
    MAX(view_raw)           AS view_raw,
    MAX(cart_raw)           AS cart_raw,
    MAX(checkout_raw)       AS checkout_raw,
    MAX(purchase_raw)       AS purchase_raw
  FROM raw_rows
  GROUP BY fullVisitorId, visitId
),
filtered AS (
  SELECT * FROM sess
  WHERE channel IS NOT NULL AND channel != '(Other)'
    AND source NOT LIKE '%.google.com'
),
flags AS (
  SELECT
    visitor_type,
    GREATEST(view_raw, cart_raw, checkout_raw, purchase_raw) AS view_m,
    GREATEST(cart_raw, checkout_raw, purchase_raw)           AS cart_m,
    GREATEST(checkout_raw, purchase_raw)                     AS checkout_m,
    purchase_raw                                             AS purchase_m
  FROM filtered
)
SELECT
  IFNULL(visitor_type, 'ВСІ') AS visitor_type,
  COUNT(*)                    AS sessions,
  COUNTIF(view_m = 1)         AS viewed_mono,
  COUNTIF(cart_m = 1)         AS cart_mono,
  COUNTIF(checkout_m = 1)     AS checkout_mono,
  COUNTIF(purchase_m = 1)     AS purchase_mono
FROM flags
GROUP BY ROLLUP(visitor_type)
ORDER BY sessions DESC;


-- 24_top_countries.csv
-- Топ-5 країн за сесіями і та сама воронка для них, з лічильником сесій
-- на кожному кроці — щоб було видно, хто з п'яти не проходить поріг 100
-- на пізніх кроках (checkout, покупка), перш ніж рахувати для них частки.
WITH raw_rows AS (
  SELECT
    fullVisitorId,
    visitId,
    channelGrouping                      AS channel,
    IFNULL(trafficSource.source, '')     AS source,
    geoNetwork.country                   AS country,

    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '2', 1, 0)) FROM UNNEST(hits) h), 0) AS view_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '3', 1, 0)) FROM UNNEST(hits) h), 0) AS cart_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '5', 1, 0)) FROM UNNEST(hits) h), 0) AS checkout_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '6', 1, 0)) FROM UNNEST(hits) h), 0) AS purchase_raw
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
),
sess AS (
  SELECT
    fullVisitorId, visitId,
    ANY_VALUE(channel) AS channel,
    ANY_VALUE(source)  AS source,
    ANY_VALUE(country) AS country,
    MAX(view_raw)      AS view_raw,
    MAX(cart_raw)      AS cart_raw,
    MAX(checkout_raw)  AS checkout_raw,
    MAX(purchase_raw)  AS purchase_raw
  FROM raw_rows
  GROUP BY fullVisitorId, visitId
),
filtered AS (
  SELECT * FROM sess
  WHERE channel IS NOT NULL AND channel != '(Other)'
    AND source NOT LIKE '%.google.com'
),
top5 AS (
  SELECT country FROM filtered
  GROUP BY country ORDER BY COUNT(*) DESC LIMIT 5
),
flags AS (
  SELECT
    country,
    GREATEST(view_raw, cart_raw, checkout_raw, purchase_raw) AS view_m,
    GREATEST(cart_raw, checkout_raw, purchase_raw)           AS cart_m,
    GREATEST(checkout_raw, purchase_raw)                     AS checkout_m,
    purchase_raw                                             AS purchase_m
  FROM filtered
  WHERE country IN (SELECT country FROM top5)
)
SELECT
  country,
  COUNT(*)                AS sessions,
  COUNTIF(view_m = 1)     AS viewed_mono,
  COUNTIF(cart_m = 1)     AS cart_mono,
  COUNTIF(checkout_m = 1) AS checkout_mono,
  COUNTIF(purchase_m = 1) AS purchase_mono
FROM flags
GROUP BY country
ORDER BY sessions DESC;


-- 25_channel_device_cross.csv
-- Перетин канал × пристрій. 8 каналів × 3 пристрої = 24 комірки; частина
-- не пройде поріг 100 сесій на пізніх кроках. sessions і purchase_mono
-- виводяться для КОЖНОЇ комірки навмисно — щоб фільтрувати за розміром
-- у пандасі, а не губити рядки мовчки на рівні SQL.
WITH raw_rows AS (
  SELECT
    fullVisitorId,
    visitId,
    channelGrouping                      AS channel,
    IFNULL(trafficSource.source, '')     AS source,
    device.deviceCategory                AS device,
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
    ANY_VALUE(device)  AS device,
    MAX(view_raw)      AS view_raw,
    MAX(purchase_raw)  AS purchase_raw
  FROM raw_rows
  GROUP BY fullVisitorId, visitId
),
filtered AS (
  SELECT * FROM sess
  WHERE channel IS NOT NULL AND channel != '(Other)'
    AND source NOT LIKE '%.google.com'
)
SELECT
  channel,
  device,
  COUNT(*)                                              AS sessions,
  COUNTIF(view_raw = 1)                                 AS viewed_mono,
  COUNTIF(purchase_raw = 1)                             AS purchase_mono,
  ROUND(100 * COUNTIF(purchase_raw = 1) / COUNT(*), 3)  AS cr_pct
FROM filtered
GROUP BY channel, device
ORDER BY channel, sessions DESC;


-- 26_return_share_by_channel.csv
-- Загальна частка повернених сесій (visitNumber > 1) по каналу — на всій
-- популяції каналу, а не лише на «прихованому direct» з 15_direct_source_vs_channel
-- (там pct_return_direct/pct_return_rest — розріз лише всередині бакету).
-- Тут одна колонка на канал, для графіка «повернені по каналах».
WITH sess AS (
  SELECT
    fullVisitorId,
    visitId,
    ANY_VALUE(channelGrouping)                   AS channel,
    ANY_VALUE(IFNULL(trafficSource.source, ''))  AS source,
    MAX(visitNumber)                             AS visit_number
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
  GROUP BY fullVisitorId, visitId
),
filtered AS (
  SELECT * FROM sess
  WHERE channel IS NOT NULL AND channel != '(Other)'
    AND source NOT LIKE '%.google.com'
)
SELECT
  channel,
  COUNT(*)                                                    AS sessions,
  COUNTIF(visit_number > 1)                                   AS returning_sessions,
  ROUND(100 * COUNTIF(visit_number > 1) / COUNT(*), 1)        AS pct_returning
FROM filtered
GROUP BY channel
ORDER BY sessions DESC;

-- 27_funnel_by_device_variants.csv
-- Додано після §5 і §7 ноутбука. Причина: два відомі артефакти вибірки лежать
-- на desktop непропорційно — затертий Referral (12,1% сесій desktop проти
-- 2,2% mobile, 45,1% усіх покупок вибірки) і Social, який на 94,7% youtube
-- (30,9% сесій desktop проти 11,0% mobile). Перший роздуває розрив унизу
-- воронки, другий стискає його на вході. Обидва зміщують результат у бік
-- підтвердження гіпотези 2, тому вона рахується у варіантах, а не на агрегаті.
--
-- Бакет затертого Referral — те саме означення, що в блоці 1:
-- channelGrouping = 'Referral', source = '(direct)', medium = '(none)',
-- 68 860 сесій. Варіант 'усі' має дати 879 171 — та сама звірка, що всюди.
-- tablet рахується, але в порівняння mobile/desktop не входить.
WITH raw_rows AS (
  SELECT
    fullVisitorId,
    visitId,
    channelGrouping                      AS channel,
    IFNULL(trafficSource.source, '')     AS source,
    IFNULL(trafficSource.medium, '')     AS medium,
    device.deviceCategory                AS device,
 
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '2', 1, 0)) FROM UNNEST(hits) h), 0) AS view_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '3', 1, 0)) FROM UNNEST(hits) h), 0) AS cart_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '5', 1, 0)) FROM UNNEST(hits) h), 0) AS checkout_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '6', 1, 0)) FROM UNNEST(hits) h), 0) AS purchase_raw
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
),
sess AS (
  SELECT
    fullVisitorId,
    visitId,
    ANY_VALUE(channel) AS channel,
    ANY_VALUE(source)  AS source,
    ANY_VALUE(medium)  AS medium,
    ANY_VALUE(device)  AS device,
    MAX(view_raw)      AS view_raw,
    MAX(cart_raw)      AS cart_raw,
    MAX(checkout_raw)  AS checkout_raw,
    MAX(purchase_raw)  AS purchase_raw
  FROM raw_rows
  GROUP BY fullVisitorId, visitId
),
filtered AS (
  SELECT * FROM sess
  WHERE channel IS NOT NULL AND channel != '(Other)'
    AND source NOT LIKE '%.google.com'
),
flags AS (
  SELECT
    device,
    IF(channel = 'Social', 1, 0)                                              AS is_social,
    IF(channel = 'Referral' AND source = '(direct)' AND medium = '(none)', 1, 0) AS is_hidden_referral,
 
    GREATEST(view_raw, cart_raw, checkout_raw, purchase_raw) AS view_m,
    GREATEST(cart_raw, checkout_raw, purchase_raw)           AS cart_m,
    GREATEST(checkout_raw, purchase_raw)                     AS checkout_m,
    purchase_raw                                             AS purchase_m,
 
    view_raw                                                                   AS view_s,
    IF(view_raw = 1 AND cart_raw = 1, 1, 0)                                    AS cart_s,
    IF(view_raw = 1 AND cart_raw = 1 AND checkout_raw = 1, 1, 0)               AS checkout_s,
    IF(view_raw = 1 AND cart_raw = 1 AND checkout_raw = 1 AND purchase_raw = 1, 1, 0) AS purchase_s
  FROM filtered
)
SELECT
  variant,
  device,
  COUNT(*)                AS sessions,
  COUNTIF(view_m = 1)     AS viewed_mono,
  COUNTIF(cart_m = 1)     AS cart_mono,
  COUNTIF(checkout_m = 1) AS checkout_mono,
  COUNTIF(purchase_m = 1) AS purchase_mono,
  COUNTIF(view_s = 1)     AS viewed_strict,
  COUNTIF(cart_s = 1)     AS cart_strict,
  COUNTIF(checkout_s = 1) AS checkout_strict,
  COUNTIF(purchase_s = 1) AS purchase_strict
FROM flags,
     UNNEST(['усі', 'без Social', 'Referral без джерела', 'без обох']) AS variant
WHERE CASE variant
        WHEN 'усі'                    THEN TRUE
        WHEN 'без Social'             THEN is_social = 0
        WHEN 'Referral без джерела'   THEN is_hidden_referral = 0
        ELSE is_social = 0 AND is_hidden_referral = 0
      END
GROUP BY variant, device
ORDER BY variant, sessions DESC;