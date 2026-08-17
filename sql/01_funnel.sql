-- sql/01_funnel.sql
-- Блок 1. Воронка по каналах.
-- bigquery-public-data.google_analytics_sample, 2016-08-01 — 2017-08-01
--
-- Виключення з блоку 0 (рішення №1 і сесії без каналу):
--   - реферали з субдоменів *.google.com (28 джерел, 23 506 сесій);
--   - сесії без визначеного каналу (120).
-- Ключ поведінкової сесії — fullVisitorId + visitId (рішення №3b):

-- 11_channel_composition.csv
-- Топ-5 джерел усередині кожної групи channelGrouping.
-- Питання: чи не тримається група на одному джерелі — тоді висновок гіпотези 1
-- буде про це джерело, а не про канал.
WITH sess AS (
  SELECT
    fullVisitorId,
    visitId,
    ANY_VALUE(channelGrouping)      AS channel,
    ANY_VALUE(trafficSource.source) AS source,
    ANY_VALUE(trafficSource.medium) AS medium
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
  GROUP BY fullVisitorId, visitId
),
filtered AS (
  SELECT *
  FROM sess
  WHERE channel IS NOT NULL
    AND channel != '(Other)'
    AND source NOT LIKE '%.google.com'   -- google.com без субдомена лишається
)
SELECT
  channel,
  source,
  medium,
  COUNT(*) AS sessions,
  ROUND(100 * COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY channel), 1) AS pct_of_channel
FROM filtered
GROUP BY channel, source, medium
QUALIFY ROW_NUMBER() OVER (PARTITION BY channel ORDER BY COUNT(*) DESC) <= 5
ORDER BY channel, sessions DESC;


-- 11b_channel_concentration.csv
-- Те саме одним числом на канал: скільки джерел і яку частку тримає найбільше.
WITH sess AS (
  SELECT
    fullVisitorId,
    visitId,
    ANY_VALUE(channelGrouping)      AS channel,
    ANY_VALUE(trafficSource.source) AS source
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
  GROUP BY fullVisitorId, visitId
),
filtered AS (
  SELECT * FROM sess
  WHERE channel IS NOT NULL AND channel != '(Other)'
    AND source NOT LIKE '%.google.com'
),
per_source AS (
  SELECT channel, source, COUNT(*) AS sessions
  FROM filtered
  GROUP BY channel, source
)
SELECT
  channel,
  SUM(sessions)                                                    AS sessions,
  COUNT(*)                                                         AS distinct_sources,
  ARRAY_AGG(source ORDER BY sessions DESC LIMIT 1)[OFFSET(0)]      AS top_source,
  ROUND(100 * MAX(sessions) / SUM(sessions), 1)                    AS top_source_pct
FROM per_source
GROUP BY channel
ORDER BY sessions DESC;


-- 11c_google_subdomains_medium.csv
-- Перевірка правила виключення: у блоці 0 воно сформульоване як
-- «реферали з *.google.com», а в SQL діє по source незалежно від medium.
-- Якщо тут будуть рядки з medium != 'referral' — правило ріже більше, ніж описано.
-- Рахує РЯДКИ, а не дедупліковані сесії — єдиний такий запит у файлі.
-- Це навмисно: число зіставляється з 23 506 із перевірки якості даних,
-- а там воно теж рядкове. Дедуплікація дала б 23 464, і звірка втратила б сенс.
SELECT
  trafficSource.medium,
  COUNT(*) AS sessions
FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
  AND trafficSource.source LIKE '%.google.com'
GROUP BY medium
ORDER BY sessions DESC;


-- 12_funnel_by_channel.csv
-- Основний артефакт блоку. П'ять рівнів × канал, дві версії воронки.
-- Конверсій тут немає навмисно: SQL дає лічильники, частки рахуються в ноутбуці,
-- щоб обидві форми (крок-до-кроку і наскрізна) бралися з одних і тих самих чисел.
-- ROLLUP додає рядок з NULL у channel — це підсумок по всіх каналах,
-- тобто головна цифра проєкту: абсолютні втрати на кожному переході.
WITH raw_rows AS (
  SELECT
    fullVisitorId,
    visitId,
    channelGrouping                      AS channel,
    IFNULL(trafficSource.source, '')     AS source,
    ARRAY_LENGTH(hits)                   AS n_hits,

    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '2', 1, 0)) FROM UNNEST(hits) h), 0) AS view_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '3', 1, 0)) FROM UNNEST(hits) h), 0) AS cart_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '5', 1, 0)) FROM UNNEST(hits) h), 0) AS checkout_raw,
    IFNULL((SELECT MAX(IF(h.eCommerceAction.action_type = '6', 1, 0)) FROM UNNEST(hits) h), 0) AS purchase_raw
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
),
sess AS (
  -- Ключ поведінкової сесії (рішення 3b): рядки, розрізані північчю, склеюються назад,
  -- інакше перегляд до 00:00 і покупка після дадуть фальшиву «покупку без перегляду».
  SELECT
    fullVisitorId,
    visitId,
    ANY_VALUE(channel)   AS channel,
    ANY_VALUE(source)    AS source,
    SUM(n_hits)          AS n_hits,
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
    channel,
    -- Монотонна (рішення 4): досягнутий крок зараховує всі попередні.
    GREATEST(view_raw, cart_raw, checkout_raw, purchase_raw) AS view_m,
    GREATEST(cart_raw, checkout_raw, purchase_raw)           AS cart_m,
    GREATEST(checkout_raw, purchase_raw)                     AS checkout_m,
    purchase_raw                                             AS purchase_m,
    -- Строга (контроль): крок зараховується лише якщо зафіксовані всі попередні події.
    view_raw                                                                   AS view_s,
    IF(view_raw = 1 AND cart_raw = 1, 1, 0)                                    AS cart_s,
    IF(view_raw = 1 AND cart_raw = 1 AND checkout_raw = 1, 1, 0)               AS checkout_s,
    IF(view_raw = 1 AND cart_raw = 1 AND checkout_raw = 1 AND purchase_raw = 1, 1, 0) AS purchase_s
  FROM filtered
)
SELECT
  IFNULL(channel, 'ВСІ КАНАЛИ') AS channel,
  COUNT(*)                      AS sessions,
  COUNTIF(view_m = 1)           AS viewed_mono,
  COUNTIF(cart_m = 1)           AS cart_mono,
  COUNTIF(checkout_m = 1)       AS checkout_mono,
  COUNTIF(purchase_m = 1)       AS purchase_mono,
  COUNTIF(view_s = 1)           AS viewed_strict,
  COUNTIF(cart_s = 1)           AS cart_strict,
  COUNTIF(checkout_s = 1)       AS checkout_strict,
  COUNTIF(purchase_s = 1)       AS purchase_strict
FROM flags
GROUP BY ROLLUP(channel)
ORDER BY sessions DESC;


-- 13_exclusions_reconciliation.csv
-- Скільки сесій лишається після всіх фільтрів. Одне число, яке має зійтися
-- з блоком 0 (902 755 сесій до виключень) і стояти в README.
WITH sess AS (
  SELECT
    fullVisitorId,
    visitId,
    ANY_VALUE(channelGrouping)                     AS channel,
    ANY_VALUE(IFNULL(trafficSource.source, ''))    AS source
  FROM `bigquery-public-data.google_analytics_sample.ga_sessions_*`
  WHERE _TABLE_SUFFIX BETWEEN '20160801' AND '20170801'
  GROUP BY fullVisitorId, visitId
)
SELECT
  COUNT(*)                                                        AS sessions_all,
  COUNTIF(channel IS NULL OR channel = '(Other)')                 AS excl_no_channel,
  COUNTIF(source LIKE '%.google.com')                             AS excl_internal_google,
  COUNTIF((channel IS NULL OR channel = '(Other)')
          AND source LIKE '%.google.com')                         AS excl_overlap,
  COUNTIF(channel IS NOT NULL AND channel != '(Other)'
          AND source NOT LIKE '%.google.com')                     AS sessions_kept
FROM sess;


-- 14_monotonic_confound.csv
-- Обмеження, обіцяне в hypotheses.md. Дві колонки, і друга важливіша.
-- pct_no_view — частка сесій із хітами, але без жодного action_type = '2'
--   (як записано в пре-реєстрації; сюди входять і ті, хто просто зайшов і пішов).
-- pct_buyers_no_view — частка САМЕ серед покупців. Це і є ставка дозапису:
--   монотонна воронка добудовує крок 1 тільки тим, хто дійшов далі.
--   Якщо це число різне по каналах — частина розкиду вгорі воронки створена методом.
WITH raw_rows AS (
  SELECT
    fullVisitorId,
    visitId,
    channelGrouping                   AS channel,
    IFNULL(trafficSource.source, '')  AS source,
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
  IFNULL(channel, 'ВСІ КАНАЛИ')                                   AS channel,
  COUNTIF(n_hits > 0)                                             AS sessions_with_hits,
  COUNTIF(n_hits > 0 AND view_raw = 0)                            AS no_view_event,
  ROUND(100 * COUNTIF(n_hits > 0 AND view_raw = 0)
        / NULLIF(COUNTIF(n_hits > 0), 0), 2)                      AS pct_no_view,
  COUNTIF(purchase_raw = 1)                                       AS purchase_sessions,
  COUNTIF(purchase_raw = 1 AND view_raw = 0)                      AS buyers_no_view,
  ROUND(100 * COUNTIF(purchase_raw = 1 AND view_raw = 0)
        / NULLIF(COUNTIF(purchase_raw = 1), 0), 2)                AS pct_buyers_no_view
FROM filtered
GROUP BY ROLLUP(channel)
ORDER BY sessions_with_hits DESC;

