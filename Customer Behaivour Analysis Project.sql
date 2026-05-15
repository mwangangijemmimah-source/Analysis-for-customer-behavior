--- the top 10% customers by a lifetime value and what segment do they belong to?
WITH customer_ltv AS (
    SELECT 
        c.customer_id,
        c.segment,
        c.city,
        c.acquisition_channel,
        COUNT(o.order_id)                              AS total_orders,
        ROUND(SUM(o.order_total)::NUMERIC, 2)          AS lifetime_value
    FROM customers c
    JOIN orders o ON c.customer_id = o.customer_id
    WHERE o.status != 'Cancelled'
    GROUP BY 
        c.customer_id,
        c.segment,
        c.city,
        c.acquisition_channel
),
percentiles AS (
    SELECT *,
        NTILE(10) OVER (ORDER BY lifetime_value DESC)  AS percentile_group
    FROM customer_ltv
)
SELECT 
    customer_id,
    segment,
    city,
    acquisition_channel,
    total_orders,
    lifetime_value,
    percentile_group
FROM percentiles
WHERE percentile_group = 1
ORDER BY lifetime_value DESC;

----.PRODUCT Frequently bought together in the same order
SELECT 
    p1.product_name AS product_1,
    p2.product_name AS product_2,
    COUNT(*) AS times_bought_together
FROM order_items oi1
JOIN order_items oi2 
    ON oi1.order_id = oi2.order_id 
    AND oi1.product_id < oi2.product_id
JOIN products p1 ON oi1.product_id = p1.product_id
JOIN products p2 ON oi2.product_id = p2.product_id
GROUP BY p1.product_name, p2.product_name
ORDER BY times_bought_together DESC
LIMIT 20;

----CUSTOMERS HAVEN'T Ordered in the las 90 days  but were previously active

WITH last_order AS (
    SELECT 
        c.customer_id,
        c.segment,
        c.city,
        c.acquisition_channel,
        MAX(o.order_date) AS last_order_date,
        COUNT(o.order_id) AS total_orders,
        ROUND(SUM(o.order_total)::NUMERIC, 2) AS total_spent
    FROM customers c
    JOIN orders o ON c.customer_id = o.customer_id
    GROUP BY 
        c.customer_id,
        c.segment,
        c.city,
        c.acquisition_channel
),
max_date AS (
    SELECT MAX(order_date) AS latest_date 
    FROM orders
)
SELECT 
    l.customer_id,
    l.segment,
    l.city,
    l.acquisition_channel,
    l.last_order_date,
    l.total_orders,
    l.total_spent
FROM last_order l, max_date m
WHERE l.last_order_date < m.latest_date - INTERVAL '90 days'
ORDER BY l.last_order_date DESC;

---"Referal" VS "Paid search customers" high Retention

SELECT 
    c.acquisition_channel,
    COUNT(DISTINCT c.customer_id)                                                    AS total_customers,
    COUNT(DISTINCT o.customer_id)                                                    AS customers_who_ordered,
    ROUND(COUNT(DISTINCT o.customer_id) * 100.0 / COUNT(DISTINCT c.customer_id), 2) AS retention_rate_pct,
    ROUND(AVG(o.order_total)::NUMERIC, 2)                                            AS avg_order_value,
    ROUND(SUM(o.order_total)::NUMERIC, 2)                                            AS total_revenue
FROM customers c
LEFT JOIN orders o ON c.customer_id = o.customer_id
WHERE c.acquisition_channel IN ('Referral', 'Paid Search')
GROUP BY c.acquisition_channel
ORDER BY retention_rate_pct DESC;

--- Device Type with Highest conversion rate

SELECT 
    device,
    COUNT(session_id)                                             AS total_sessions,
    SUM(converted)                                               AS total_conversions,
    ROUND(SUM(converted) * 100.0 / COUNT(session_id), 2)        AS conversion_rate_pct
FROM sessions
GROUP BY device
ORDER BY conversion_rate_pct DESC;

--- Longer sessions durations- Highest Coversion rate

SELECT 
    CASE 
        WHEN session_duration_sec < 60   THEN '1. Under 1 min'
        WHEN session_duration_sec < 300  THEN '2. 1 - 5 mins'
        WHEN session_duration_sec < 600  THEN '3. 5 - 10 mins'
        WHEN session_duration_sec < 1800 THEN '4. 10 - 30 mins'
        ELSE                                  '5. Over 30 mins'
    END AS duration_bucket,
    COUNT(session_id)                                            AS total_sessions,
    SUM(converted)                                               AS total_conversions,
    ROUND(SUM(converted) * 100.0 / COUNT(session_id), 2)        AS conversion_rate_pct,
    ROUND(AVG(session_duration_sec) / 60.0, 2)                  AS avg_duration_mins
FROM sessions
GROUP BY duration_bucket
ORDER BY duration_bucket;

--- Month-Over- Month revenue growth which months has highest spikes or drops

WITH monthly_revenue AS (
    SELECT 
        DATE_TRUNC('month', order_date)            AS order_month,
        ROUND(SUM(order_total)::NUMERIC, 2)        AS total_revenue
    FROM orders
    WHERE status != 'Cancelled'
    GROUP BY DATE_TRUNC('month', order_date)
),
revenue_growth AS (
    SELECT 
        order_month,
        total_revenue,
        LAG(total_revenue) OVER (ORDER BY order_month) AS prev_month_revenue,
        ROUND(
            (total_revenue - LAG(total_revenue) OVER (ORDER BY order_month)) 
            * 100.0 / 
            NULLIF(LAG(total_revenue) OVER (ORDER BY order_month), 0)
        , 2) AS growth_pct
    FROM monthly_revenue
)
SELECT 
    TO_CHAR(order_month, 'Month YYYY')             AS month,
    total_revenue,
    prev_month_revenue,
    growth_pct,
    CASE 
        WHEN growth_pct > 20  THEN '📈 Big Spike'
        WHEN growth_pct > 0   THEN '↑ Growth'
        WHEN growth_pct < -20 THEN '📉 Big Drop'
        WHEN growth_pct < 0   THEN '↓ Decline'
        ELSE                       '→ Flat'
    END AS trend
FROM revenue_growth
ORDER BY order_month;
--- Acquisition channell delivering highest revenue per customer over their lifetime

SELECT 
    c.acquisition_channel,
    COUNT(DISTINCT c.customer_id)                                     AS total_customers,
    ROUND(SUM(o.order_total)::NUMERIC, 2)                             AS total_revenue,
    ROUND(AVG(o.order_total)::NUMERIC, 2)                             AS avg_order_value,
    COUNT(o.order_id)                                                 AS total_orders,
    ROUND(SUM(o.order_total)::NUMERIC / 
          NULLIF(COUNT(DISTINCT c.customer_id), 0), 2)                AS revenue_per_customer
FROM customers c
LEFT JOIN orders o ON c.customer_id = o.customer_id
WHERE o.status != 'Cancelled'
GROUP BY c.acquisition_channel
ORDER BY revenue_per_customer DESC;

--- RFM Score for every customer and rank them

WITH rfm_base AS (
    SELECT 
        c.customer_id,
        c.segment,
        c.city,
        c.acquisition_channel,
        MAX(o.order_date)                           AS last_order_date,
        COUNT(o.order_id)                           AS frequency,
        ROUND(SUM(o.order_total)::NUMERIC, 2)       AS monetary
    FROM customers c
    JOIN orders o ON c.customer_id = o.customer_id
    WHERE o.status != 'Cancelled'
    GROUP BY 
        c.customer_id,
        c.segment,
        c.city,
        c.acquisition_channel
),
max_date AS (
    SELECT MAX(order_date) AS latest_date 
    FROM orders
),
rfm_scores AS (
    SELECT 
        r.customer_id,
        r.segment,
        r.city,
        r.acquisition_channel,
        r.last_order_date,
        r.frequency,
        r.monetary,
        NTILE(5) OVER (ORDER BY r.last_order_date DESC)  AS recency_score,
        NTILE(5) OVER (ORDER BY r.frequency ASC)         AS frequency_score,
        NTILE(5) OVER (ORDER BY r.monetary ASC)          AS monetary_score
    FROM rfm_base r, max_date m
),
rfm_final AS (
    SELECT *,
        recency_score + frequency_score + monetary_score AS rfm_total_score,
        CASE 
            WHEN recency_score + frequency_score + monetary_score >= 13 THEN 'Champion'
            WHEN recency_score + frequency_score + monetary_score >= 10 THEN 'Loyal Customer'
            WHEN recency_score + frequency_score + monetary_score >= 7  THEN 'Potential Loyalist'
            WHEN recency_score + frequency_score + monetary_score >= 5  THEN 'At Risk'
            ELSE                                                              'Lost Customer'
        END AS customer_label
    FROM rfm_scores
)
SELECT 
    customer_id,
    segment,
    city,
    acquisition_channel,
    last_order_date,
    frequency,
    monetary,
    recency_score,
    frequency_score,
    monetary_score,
    rfm_total_score,
    customer_label,
    RANK() OVER (ORDER BY rfm_total_score DESC) AS customer_rank
FROM rfm_final
ORDER BY customer_rank;

--- Gross Margin per product category

SELECT 
    p.category,
    COUNT(DISTINCT p.product_id)                              AS total_products,
    SUM(oi.quantity)                                          AS total_units_sold,
    ROUND(SUM(oi.line_total)::NUMERIC, 2)                     AS total_revenue,
    ROUND(SUM(p.cost * oi.quantity)::NUMERIC, 2)              AS total_cost,
    ROUND((SUM(oi.line_total) - 
           SUM(p.cost * oi.quantity))::NUMERIC, 2)            AS gross_profit,
    ROUND((SUM(oi.line_total) - SUM(p.cost * oi.quantity)) 
           * 100.0 / NULLIF(SUM(oi.line_total), 0), 2)        AS gross_margin_pct
FROM products p
JOIN order_items oi ON p.product_id = oi.product_id
JOIN orders o ON oi.order_id = o.order_id
WHERE o.status != 'Cancelled'
GROUP BY p.category
ORDER BY gross_margin_pct DESC;





