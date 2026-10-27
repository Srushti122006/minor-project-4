USE bingeplay;

SELECT 'users' AS tbl, COUNT(*) AS total FROM users
UNION ALL
SELECT 'subscriptions', COUNT(*) FROM subscriptions
UNION ALL
SELECT 'shows', COUNT(*) FROM shows
UNION ALL
SELECT 'watch_sessions', COUNT(*) FROM watch_sessions
UNION ALL
SELECT 'ratings', COUNT(*) FROM ratings;
-----------------------------------------------------------------------
-- Foundations
-----------------------------------------------------------------------
SELECT
    COUNT(*) AS active_subscriptions,
    SUM(monthly_price_inr) AS monthly_revenue_inr
FROM subscriptions
WHERE status = 'active'
  AND (
      end_date IS NULL
      OR end_date > '2024-06-30'
  );
  
  SELECT
    MONTH(signup_date) AS month_number,
    MONTHNAME(signup_date) AS month,
    COUNT(*) AS signup_count
FROM users
WHERE signup_date >= '2024-01-01'
  AND signup_date < '2024-07-01'
GROUP BY
    MONTH(signup_date),
    MONTHNAME(signup_date)
ORDER BY month_number;

SELECT
    MONTHNAME(signup_date) AS month,
    COUNT(*) AS signup_count
FROM users
WHERE signup_date >= '2024-01-01'
  AND signup_date < '2024-07-01'
GROUP BY MONTH(signup_date), MONTHNAME(signup_date)
ORDER BY signup_count DESC
LIMIT 1;

SELECT
    device_type,
    COUNT(*) AS total_sessions,
    SUM(watch_minutes) AS total_watch_minutes,
    ROUND(AVG(watch_minutes), 2) AS avg_watch_minutes,
    ROUND(
        100.0 * SUM(CASE WHEN completed = 1 THEN 1 ELSE 0 END)
        / COUNT(*),
        2
    ) AS completion_rate_pct
FROM watch_sessions
WHERE user_id IS NOT NULL
GROUP BY device_type
ORDER BY device_type;

SELECT
    stars,
    COUNT(*) AS rating_count,
    ROUND(
        100.0 * COUNT(*) / (SELECT COUNT(*) FROM ratings),
        2
    ) AS percentage
FROM ratings
GROUP BY stars
ORDER BY stars;

SELECT
    COUNT(*) AS total_ratings,
    SUM(CASE WHEN stars >= 4 THEN 1 ELSE 0 END)
        AS four_or_five_star_ratings,
    ROUND(
        100.0 * SUM(CASE WHEN stars >= 4 THEN 1 ELSE 0 END)
        / COUNT(*),
        2
    ) AS four_or_five_star_percentage
FROM ratings;

SELECT
    CASE
        WHEN is_original = 1 THEN 'BingePlay Originals'
        ELSE 'Acquired Content'
    END AS content_type,
    COUNT(*) AS number_of_shows,
    ROUND(AVG(imdb_rating), 2) AS avg_imdb_rating,
    ROUND(AVG(release_year), 2) AS avg_release_year
FROM shows
GROUP BY is_original
ORDER BY is_original DESC;
------------------------------------------------------------------------
-- Joins and subqueries
------------------------------------------------------------------------
WITH binge_days AS (
    SELECT
        user_id,
        show_id,
        session_date,
        COUNT(*) AS sessions_in_day
    FROM watch_sessions
    WHERE user_id IS NOT NULL
      AND session_date >= '2024-04-01'
      AND session_date < '2024-07-01'
    GROUP BY user_id, show_id, session_date
    HAVING COUNT(*) >= 5
)
SELECT
    COUNT(*) AS total_binge_days
FROM binge_days;

WITH binge_days AS (
    SELECT
        user_id,
        show_id,
        session_date
    FROM watch_sessions
    WHERE user_id IS NOT NULL
      AND session_date >= '2024-04-01'
      AND session_date < '2024-07-01'
    GROUP BY user_id, show_id, session_date
    HAVING COUNT(*) >= 5
)
SELECT
    user_id,
    COUNT(*) AS binge_day_count
FROM binge_days
GROUP BY user_id
ORDER BY binge_day_count DESC, user_id
LIMIT 1;

SELECT
    COUNT(*) AS total_q1_signups,
    SUM(
        CASE
            WHEN NOT EXISTS (
                SELECT 1
                FROM watch_sessions ws
                WHERE ws.user_id = u.user_id
            )
            THEN 1
            ELSE 0
        END
    ) AS never_watched_users
FROM users u
WHERE u.signup_date >= '2024-01-01'
  AND u.signup_date < '2024-04-01';
  
WITH current_plans AS (
    SELECT
        s.*,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY start_date DESC, subscription_id DESC
        ) AS rn
    FROM subscriptions s
    WHERE start_date <= '2024-06-30'
      AND status = 'active'
      AND (
          end_date IS NULL
          OR end_date > '2024-06-30'
      )
)
SELECT COUNT(*) AS overpaying_users
FROM current_plans cp
WHERE cp.rn = 1
  AND cp.Plan IN ('Premium', 'Family')
  AND EXISTS (
      SELECT 1
      FROM watch_sessions ws
      WHERE ws.user_id = cp.user_id
  )
  AND NOT EXISTS (
      SELECT 1
      FROM watch_sessions ws
      JOIN shows sh ON sh.show_id = ws.show_id
      WHERE ws.user_id = cp.user_id
        AND sh.min_plan IN ('Premium', 'Family')
  );
  
  WITH ranked_subscriptions AS (
    SELECT
        s.*,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY start_date, subscription_id
        ) AS rn
    FROM subscriptions s
),
first_plans AS (
    SELECT user_id, Plan AS first_plan
    FROM ranked_subscriptions
    WHERE rn = 1
),
first_upgrades AS (
    SELECT
        s.user_id,
        MIN(s.start_date) AS first_upgrade_date
    FROM subscriptions s
    JOIN first_plans fp
      ON fp.user_id = s.user_id
    WHERE fp.first_plan = 'Basic'
      AND s.Plan IN ('Premium', 'Family')
    GROUP BY s.user_id
),
eligible_users AS (
    SELECT
        u.user_id,
        DATEDIFF(fu.first_upgrade_date, u.signup_date)
            AS days_to_upgrade
    FROM users u
    JOIN first_plans fp
      ON fp.user_id = u.user_id
    JOIN first_upgrades fu
      ON fu.user_id = u.user_id
    WHERE u.signup_date >= '2024-01-01'
      AND u.signup_date < '2024-02-01'
      AND fp.first_plan = 'Basic'
      AND EXISTS (
          SELECT 1
          FROM subscriptions s
          WHERE s.user_id = u.user_id
            AND s.start_date <= '2024-06-30'
            AND s.status = 'active'
            AND (
                s.end_date IS NULL
                OR s.end_date > '2024-06-30'
            )
      )
)
SELECT
    COUNT(*) AS upgraded_active_users,
    ROUND(AVG(days_to_upgrade), 2) AS avg_days_to_upgrade
FROM eligible_users;

WITH comeback_events AS (
    SELECT DISTINCT
        first_session.user_id,
        first_session.show_id,
        first_session.session_date AS incomplete_date
    FROM watch_sessions first_session
    JOIN watch_sessions next_session
      ON next_session.user_id = first_session.user_id
     AND next_session.show_id = first_session.show_id
     AND next_session.session_date
         BETWEEN DATE_ADD(first_session.session_date, INTERVAL 1 DAY)
             AND DATE_ADD(first_session.session_date, INTERVAL 7 DAY)
    WHERE first_session.user_id IS NOT NULL
      AND first_session.completed = 0
)
SELECT
    COUNT(*) AS total_comeback_events
FROM comeback_events;

WITH comeback_events AS (
    SELECT DISTINCT
        first_session.user_id,
        first_session.show_id,
        first_session.session_date AS incomplete_date
    FROM watch_sessions first_session
    JOIN watch_sessions next_session
      ON next_session.user_id = first_session.user_id
     AND next_session.show_id = first_session.show_id
     AND next_session.session_date
         BETWEEN DATE_ADD(first_session.session_date, INTERVAL 1 DAY)
             AND DATE_ADD(first_session.session_date, INTERVAL 7 DAY)
    WHERE first_session.user_id IS NOT NULL
      AND first_session.completed = 0
)
SELECT
    ce.show_id,
    sh.title,
    COUNT(*) AS comeback_events
FROM comeback_events ce
JOIN shows sh ON sh.show_id = ce.show_id
GROUP BY ce.show_id, sh.title
ORDER BY comeback_events DESC, ce.show_id
LIMIT 1;

---------------------------------------------------------------------------
-- Advanced SQL
---------------------------------------------------------------------------
WITH weekly_activity AS (
    SELECT DISTINCT
        user_id,
        DATE_SUB(
            session_date,
            INTERVAL WEEKDAY(session_date) DAY
        ) AS week_start
    FROM watch_sessions
    WHERE user_id IS NOT NULL
),
numbered_weeks AS (
    SELECT
        user_id,
        week_start,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY week_start
        ) AS rn
    FROM weekly_activity
),
streak_groups AS (
    SELECT
        user_id,
        week_start,
        DATE_SUB(
            week_start,
            INTERVAL rn WEEK
        ) AS streak_group
    FROM numbered_weeks
),
streaks AS (
    SELECT
        user_id,
        streak_group,
        COUNT(*) AS streak_weeks
    FROM streak_groups
    GROUP BY user_id, streak_group
)
SELECT
    COUNT(DISTINCT CASE
        WHEN streak_weeks >= 4 THEN user_id
    END) AS users_with_4_week_streak,
    MAX(streak_weeks) AS longest_streak_weeks
FROM streaks;

WITH weekly_activity AS (
    SELECT DISTINCT
        user_id,
        DATE_SUB(
            session_date,
            INTERVAL WEEKDAY(session_date) DAY
        ) AS week_start
    FROM watch_sessions
    WHERE user_id IS NOT NULL
),
numbered_weeks AS (
    SELECT
        user_id,
        week_start,
        ROW_NUMBER() OVER (
            PARTITION BY user_id
            ORDER BY week_start
        ) AS rn
    FROM weekly_activity
),
streak_groups AS (
    SELECT
        user_id,
        DATE_SUB(week_start, INTERVAL rn WEEK) AS streak_group
    FROM numbered_weeks
),
streaks AS (
    SELECT
        user_id,
        streak_group,
        COUNT(*) AS streak_weeks
    FROM streak_groups
    GROUP BY user_id, streak_group
)
SELECT user_id, streak_weeks
FROM streaks
ORDER BY streak_weeks DESC, user_id
LIMIT 1;

WITH monthly_activity AS (
    SELECT
        user_id,
        SUM(
            CASE
                WHEN session_date >= '2024-05-01'
                 AND session_date < '2024-06-01'
                THEN watch_minutes
                ELSE 0
            END
        ) AS may_minutes,
        SUM(
            CASE
                WHEN session_date >= '2024-06-01'
                 AND session_date < '2024-07-01'
                THEN watch_minutes
                ELSE 0
            END
        ) AS june_minutes
    FROM watch_sessions
    WHERE user_id IS NOT NULL
      AND session_date >= '2024-05-01'
      AND session_date < '2024-07-01'
    GROUP BY user_id
),
churn_signals AS (
    SELECT
        user_id,
        may_minutes,
        june_minutes,
        ROUND(
            100.0 * (may_minutes - june_minutes) / may_minutes,
            2
        ) AS drop_percentage
    FROM monthly_activity
    WHERE may_minutes > 0
      AND june_minutes <= may_minutes * 0.5
)
SELECT
    u.user_id,
    u.name,
    cs.may_minutes,
    cs.june_minutes,
    cs.drop_percentage
FROM churn_signals cs
JOIN users u ON u.user_id = cs.user_id
ORDER BY cs.drop_percentage DESC, u.user_id;

WITH monthly_activity AS (
    SELECT
        user_id,
        SUM(
            CASE
                WHEN session_date >= '2024-05-01'
                 AND session_date < '2024-06-01'
                THEN watch_minutes ELSE 0
            END
        ) AS may_minutes,
        SUM(
            CASE
                WHEN session_date >= '2024-06-01'
                 AND session_date < '2024-07-01'
                THEN watch_minutes ELSE 0
            END
        ) AS june_minutes
    FROM watch_sessions
    WHERE user_id IS NOT NULL
      AND session_date >= '2024-05-01'
      AND session_date < '2024-07-01'
    GROUP BY user_id
)
SELECT COUNT(*) AS total_churn_signal_users
FROM monthly_activity
WHERE may_minutes > 0
  AND june_minutes <= may_minutes * 0.5;
  

