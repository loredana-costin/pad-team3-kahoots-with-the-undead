-- Data warehouse (kahoots_dw): a star schema loaded by etl.py from every service database.
-- Applied by the ETL job on every start; every statement is idempotent.
-- There are no foreign keys on purpose: each source is loaded on its own, and a fact may name a
-- player or a type whose source was down in that run. Join on the ids.

-- ---------------------------------------------------------------- dimensions

-- Calendar, one row per day. Facts point at it with date_key = YYYYMMDD.
CREATE TABLE IF NOT EXISTS dim_date (
    date_key   INTEGER PRIMARY KEY,
    date       DATE    NOT NULL,
    year       INTEGER NOT NULL,
    month      INTEGER NOT NULL,
    day        INTEGER NOT NULL,
    weekday    TEXT    NOT NULL,
    is_weekend BOOLEAN NOT NULL
);

INSERT INTO dim_date
SELECT to_char(d, 'YYYYMMDD')::int, d, extract(year FROM d), extract(month FROM d), extract(day FROM d),
       trim(to_char(d, 'Day')), extract(isodow FROM d) >= 6
FROM generate_series('2025-01-01'::date, '2030-12-31'::date, interval '1 day') AS g(d)
ON CONFLICT (date_key) DO NOTHING;

-- Player Service. No email and no password hash: only the id and the public names.
CREATE TABLE IF NOT EXISTS dim_player (
    player_id     TEXT PRIMARY KEY,
    username      TEXT NOT NULL,
    nickname      TEXT NOT NULL,
    group_name    TEXT NOT NULL,
    xp            INTEGER NOT NULL,
    level         INTEGER NOT NULL,
    registered_at TIMESTAMPTZ NOT NULL,
    loaded_at     TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Exam Service
CREATE TABLE IF NOT EXISTS dim_exam (
    exam_id           INTEGER PRIMARY KEY,
    course_name       TEXT NOT NULL,
    course_category   TEXT NOT NULL,
    passing_threshold INTEGER NOT NULL,
    question_count    INTEGER NOT NULL,
    loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- World Service: rooms with their zone flattened in.
CREATE TABLE IF NOT EXISTS dim_room (
    room_name      TEXT PRIMARY KEY,
    full_room_name TEXT NOT NULL,
    room_type      TEXT NOT NULL,
    resource_type  TEXT,
    zone_name      TEXT NOT NULL,
    zone_title     TEXT NOT NULL,
    zone_unlocked  BOOLEAN NOT NULL,
    spawn_points   INTEGER NOT NULL,
    loaded_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Resource Service
CREATE TABLE IF NOT EXISTS dim_resource_type (
    resource_type_id TEXT PRIMARY KEY,
    name             TEXT NOT NULL,
    stackable        BOOLEAN NOT NULL,
    loaded_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Zombie Service (MongoDB)
CREATE TABLE IF NOT EXISTS dim_zombie_type (
    zombie_type_id  TEXT PRIMARY KEY,
    name            TEXT NOT NULL,
    category        TEXT NOT NULL,
    base_health     INTEGER NOT NULL,
    attack_strength INTEGER NOT NULL,
    special_ability TEXT NOT NULL,
    curable         BOOLEAN NOT NULL,
    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Crafting Service
CREATE TABLE IF NOT EXISTS dim_recipe (
    recipe_id   TEXT PRIMARY KEY,
    name        TEXT NOT NULL,
    output_item TEXT NOT NULL,
    unlock_type TEXT NOT NULL,
    ingredients TEXT NOT NULL, -- e.g. "wood x3, metal x1"
    loaded_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- facts

-- Game Service
CREATE TABLE IF NOT EXISTS fact_game_session (
    session_id       TEXT PRIMARY KEY,
    date_key         INTEGER NOT NULL,
    zone_id          TEXT NOT NULL,
    status           TEXT NOT NULL,
    player_count     INTEGER NOT NULL,
    max_players      INTEGER NOT NULL,
    cycle_number     INTEGER NOT NULL,
    started_at       TIMESTAMPTZ,
    finished_at      TIMESTAMPTZ,
    duration_seconds INTEGER,
    loaded_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS fact_player_action (
    action_id        TEXT PRIMARY KEY,
    date_key         INTEGER NOT NULL,
    session_id       TEXT NOT NULL,
    player_id        TEXT NOT NULL,
    action_type      TEXT NOT NULL,
    target_node_id   TEXT NOT NULL,
    status           TEXT NOT NULL,
    duration_seconds INTEGER NOT NULL,
    started_at       TIMESTAMPTZ NOT NULL,
    loaded_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Player Service
CREATE TABLE IF NOT EXISTS fact_trade (
    trade_id       TEXT PRIMARY KEY,
    date_key       INTEGER NOT NULL,
    from_player_id TEXT NOT NULL,
    to_player_id   TEXT NOT NULL,
    items_offered   INTEGER NOT NULL,
    items_requested INTEGER NOT NULL,
    loaded_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Exam Service
CREATE TABLE IF NOT EXISTS fact_exam_attempt (
    attempt_id       INTEGER PRIMARY KEY,
    date_key         INTEGER NOT NULL,
    player_id        TEXT NOT NULL,
    exam_id          INTEGER NOT NULL,
    course_category  TEXT NOT NULL,
    status           TEXT NOT NULL,
    passed           BOOLEAN NOT NULL,
    grade            INTEGER,
    correct_count    INTEGER,
    total_questions  INTEGER,
    duration_seconds INTEGER,
    loaded_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Resource Service: one row per ledger entry (gather, spend, refund).
CREATE TABLE IF NOT EXISTS fact_resource_transaction (
    idempotency_key TEXT PRIMARY KEY,
    date_key        INTEGER NOT NULL,
    player_id       TEXT NOT NULL,
    operation       TEXT NOT NULL,
    amount_gathered INTEGER NOT NULL, -- 0 for spend and refund
    created_at      TIMESTAMPTZ NOT NULL,
    loaded_at       TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Resource Service: daily snapshot of every balance; a rerun on the same day overwrites that day.
CREATE TABLE IF NOT EXISTS fact_resource_balance (
    snapshot_date_key INTEGER NOT NULL,
    player_id         TEXT NOT NULL,
    resource_type_id  TEXT NOT NULL,
    quantity          INTEGER NOT NULL,
    loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (snapshot_date_key, player_id, resource_type_id)
);

-- Crafting Service
CREATE TABLE IF NOT EXISTS fact_craft (
    craft_id         TEXT PRIMARY KEY,
    date_key         INTEGER NOT NULL,
    player_id        TEXT NOT NULL,
    recipe_id        TEXT NOT NULL,
    status           TEXT NOT NULL,
    succeeded        BOOLEAN NOT NULL,
    item_delivered   TEXT,
    duration_seconds INTEGER,
    loaded_at        TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- Base Service: daily snapshot of every base.
CREATE TABLE IF NOT EXISTS fact_base_snapshot (
    snapshot_date_key INTEGER NOT NULL,
    player_id         TEXT NOT NULL,
    kiki_mood         TEXT NOT NULL,
    rooms_claimed     INTEGER NOT NULL,
    barricade_levels  INTEGER NOT NULL,
    facility_levels   INTEGER NOT NULL,
    decorations       INTEGER NOT NULL,
    morale_bonus      INTEGER NOT NULL,
    loaded_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (snapshot_date_key, player_id)
);

-- Zombie Service (MongoDB). Instances expire in the source after 4 hours; here they are kept.
CREATE TABLE IF NOT EXISTS fact_zombie_instance (
    instance_id    TEXT PRIMARY KEY,
    date_key       INTEGER NOT NULL,
    zombie_type_id TEXT NOT NULL,
    category       TEXT NOT NULL,
    zone_id        TEXT NOT NULL,
    spawn_point    TEXT NOT NULL,
    cycle_id       TEXT NOT NULL,
    health         INTEGER NOT NULL,
    spawned_at     TIMESTAMPTZ NOT NULL,
    loaded_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------- bookkeeping

CREATE TABLE IF NOT EXISTS etl_runs (
    run_id      SERIAL PRIMARY KEY,
    started_at  TIMESTAMPTZ NOT NULL,
    finished_at TIMESTAMPTZ,
    status      TEXT NOT NULL, -- ok, partial (a source or table was skipped); running if the warehouse dropped mid-run
    rows_loaded JSONB NOT NULL DEFAULT '{}',
    errors      JSONB NOT NULL DEFAULT '[]'
);
