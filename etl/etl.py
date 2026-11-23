"""Extract-transform-load job: copies every service database into the data warehouse (kahoots_dw).

Runs once at startup and then every ETL_INTERVAL_SECONDS; `python etl.py --once` runs a single pass.
Sources are read in read-only sessions. A source or table that fails is logged and skipped, and the
run is marked partial. Loads are upserts, so running it again never duplicates a row.
"""

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import psycopg
from psycopg import sql
from psycopg.rows import dict_row
from pymongo import MongoClient

XP_PER_LEVEL = 200  # Player Service's LevelCalculator
SESSION_STATUS = {0: "lobby", 1: "active", 2: "finished"}
ACTION_TYPE = {0: "chop", 1: "scavenge", 2: "clear", 3: "barricade", 4: "repair", 5: "upgrade"}
ACTION_STATUS = {0: "in_progress", 1: "completed", 2: "cancelled", 3: "completing"}


def log(level, event, **fields):
    print(json.dumps({"ts": datetime.now(timezone.utc).isoformat(), "level": level,
                      "service": "etl-service", "event": event, **fields}, default=str), flush=True)


# ---------------------------------------------------------------- transform (pure functions)

def date_key(value):
    """2026-11-23 -> 20261123; works for dates and datetimes."""
    return int(value.strftime("%Y%m%d")) if value else None


def seconds_between(start, end):
    return int((end - start).total_seconds()) if start and end else None


def player(r):
    # Only the id and public names: email and password_hash are never selected or loaded.
    return {"player_id": r["id"], "username": r["username"], "nickname": r["nickname"],
            "group_name": r["group_name"], "xp": r["xp"], "level": max(1, r["xp"] // XP_PER_LEVEL),
            "registered_at": r["created_on_utc"]}


def trade(r):
    return {"trade_id": r["id"], "date_key": date_key(r["created_on_utc"]),
            "from_player_id": r["from_player_id"], "to_player_id": r["to_player_id"],
            "items_offered": r["items_offered"], "items_requested": r["items_requested"]}


def game_session(r):
    return {"session_id": r["id"], "date_key": date_key(r["created_on_utc"]), "zone_id": r["zone_id"],
            "status": SESSION_STATUS.get(r["status"], "unknown"), "player_count": r["player_count"],
            "max_players": r["max_players"], "cycle_number": r["cycle_number"],
            "started_at": r["started_at"], "finished_at": r["finished_at"],
            "duration_seconds": seconds_between(r["started_at"], r["finished_at"])}


def player_action(r):
    return {"action_id": r["id"], "date_key": date_key(r["started_at"]), "session_id": r["session_id"],
            "player_id": r["player_id"], "action_type": ACTION_TYPE.get(r["action_type"], "unknown"),
            "target_node_id": r["target_node_id"], "status": ACTION_STATUS.get(r["status"], "unknown"),
            "duration_seconds": r["duration_seconds"], "started_at": r["started_at"]}


def exam(r):
    return {"exam_id": r["id"], "course_name": r["course_name"], "course_category": r["course_category"],
            "passing_threshold": r["passing_threshold"], "question_count": len(r["questions"] or [])}


def exam_attempt(r):
    return {"attempt_id": r["id"], "date_key": date_key(r["started_at"]), "player_id": r["player_id"],
            "exam_id": r["exam_record_id"], "course_category": r["course_category"],
            "status": r["status"], "passed": r["status"] == "passed", "grade": r["grade"],
            "correct_count": r["correct_count"], "total_questions": r["total_questions"],
            "duration_seconds": seconds_between(r["started_at"], r["finished_at"])}


def room(r):
    return {"room_name": r["room_name"], "full_room_name": r["full_room_name"], "room_type": r["type"],
            "resource_type": r["resource_type"], "zone_name": r["zone_name"], "zone_title": r["zone_title"],
            "zone_unlocked": r["unlocked"], "spawn_points": r["spawn_points"]}


def resource_type(r):
    return {"resource_type_id": r["resource_type_id"], "name": r["name"], "stackable": r["stackable"]}


def resource_transaction(r):
    gathered = (r["result"] or {}).get("gathered", 0) if r["operation"] == "gather" else 0
    return {"idempotency_key": r["idempotency_key"], "date_key": date_key(r["created_at"]),
            "player_id": r["player_id"], "operation": r["operation"], "amount_gathered": int(gathered),
            "created_at": r["created_at"]}


def resource_balances(r):
    """One inventory row ({"wood": 10, "metal": 5}) -> one balance row per resource type."""
    return [{"snapshot_date_key": date_key(r["snapshot_date"]), "player_id": r["player_id"],
             "resource_type_id": resource, "quantity": int(quantity)}
            for resource, quantity in (r["resources"] or {}).items()]


def base_snapshot(r):
    return {"snapshot_date_key": date_key(r["snapshot_date"]), "player_id": r["player_id"],
            "kiki_mood": r["kiki_mood"], "rooms_claimed": r["rooms_claimed"],
            "barricade_levels": r["barricade_levels"], "facility_levels": r["facility_levels"],
            "decorations": r["decorations"], "morale_bonus": r["morale_bonus"]}


def recipe(r):
    return {"recipe_id": r["recipe_id"], "name": r["name"], "output_item": r["output"],
            "unlock_type": r["unlock_type"] or "none", "ingredients": r["ingredients"] or ""}


def craft(r):
    return {"craft_id": r["craft_id"], "date_key": date_key(r["created_at"]), "player_id": r["player_id"],
            "recipe_id": r["recipe_id"], "status": r["status"], "succeeded": r["status"] == "completed",
            "item_delivered": r["item_delivered"],
            "duration_seconds": seconds_between(r["created_at"], r["completed_at"])}


def zombie_type(d):
    return {"zombie_type_id": d["_id"], "name": d["name"], "category": d["category"],
            "base_health": d["baseHealth"], "attack_strength": d["attackStrength"],
            "special_ability": d["specialAbility"], "curable": bool(d.get("curable"))}


def zombie_instance(d):
    return {"instance_id": d["_id"], "date_key": date_key(d["createdAt"]), "zombie_type_id": d["typeId"],
            "category": d["category"], "zone_id": d["worldZoneId"], "spawn_point": d["spawnPoint"],
            "cycle_id": d["cycleId"], "health": d["health"], "spawned_at": d["createdAt"]}


# ---------------------------------------------------------------- extract queries per source
# source -> [(warehouse table, key columns, query, transform)]. For zombie the query is a collection name.

JOBS = {
    "player": [
        ("dim_player", ["player_id"],
         "SELECT id, username, nickname, group_name, xp, created_on_utc FROM players", player),
        ("fact_trade", ["trade_id"],
         """SELECT t.id, t.from_player_id, t.to_player_id, t.created_on_utc,
                   coalesce(sum(i.quantity) FILTER (WHERE i.side = 0), 0)::int AS items_offered,
                   coalesce(sum(i.quantity) FILTER (WHERE i.side = 1), 0)::int AS items_requested
            FROM trades t LEFT JOIN trade_items i ON i.trade_id = t.id GROUP BY t.id""", trade),
    ],
    "game": [
        ("fact_game_session", ["session_id"],
         """SELECT s.*, (SELECT count(*) FROM session_players p WHERE p.session_id = s.id)::int AS player_count
            FROM game_sessions s""", game_session),
        ("fact_player_action", ["action_id"], "SELECT * FROM player_actions", player_action),
    ],
    "exam": [
        ("dim_exam", ["exam_id"], "SELECT * FROM exams", exam),
        ("fact_exam_attempt", ["attempt_id"], "SELECT * FROM attempts", exam_attempt),
    ],
    "world": [
        ("dim_room", ["room_name"],
         """SELECT r.room_name, r.full_room_name, r.type, r.resource_type, z.zone_name, z.name AS zone_title,
                   z.unlocked, (SELECT count(*) FROM spawn_points s WHERE s.room_record_id = r.id)::int AS spawn_points
            FROM rooms r JOIN zones z ON z.id = r.zone_record_id""", room),
    ],
    "resource": [
        ("dim_resource_type", ["resource_type_id"], "SELECT * FROM resource_types", resource_type),
        ("fact_resource_transaction", ["idempotency_key"], "SELECT * FROM resource_transactions", resource_transaction),
        ("fact_resource_balance", ["snapshot_date_key", "player_id", "resource_type_id"],
         "SELECT player_id, resources, current_date AS snapshot_date FROM inventories", resource_balances),
    ],
    "base": [
        ("fact_base_snapshot", ["snapshot_date_key", "player_id"],
         """SELECT b.player_id, b.kiki_mood, current_date AS snapshot_date,
                   (SELECT count(*) FROM base_rooms r WHERE r.player_id = b.player_id)::int AS rooms_claimed,
                   (SELECT coalesce(sum(barricade_level), 0) FROM base_rooms r WHERE r.player_id = b.player_id)::int AS barricade_levels,
                   (SELECT coalesce(sum(level), 0) FROM facilities f WHERE f.player_id = b.player_id)::int AS facility_levels,
                   (SELECT count(*) FROM decorations d WHERE d.player_id = b.player_id)::int AS decorations,
                   (SELECT coalesce(sum(morale_bonus), 0) FROM decorations d WHERE d.player_id = b.player_id)::int AS morale_bonus
            FROM bases b""", base_snapshot),
    ],
    "crafting": [
        ("dim_recipe", ["recipe_id"],
         """SELECT r.recipe_id, r.name, r.output, r.unlock_type,
                   string_agg(i.resource_type || ' x' || i.amount, ', ' ORDER BY i.position) AS ingredients
            FROM recipes r LEFT JOIN recipe_ingredients i ON i.recipe_id = r.recipe_id GROUP BY r.recipe_id""", recipe),
        ("fact_craft", ["craft_id"], "SELECT * FROM craft_attempts", craft),
    ],
    "zombie": [
        ("dim_zombie_type", ["zombie_type_id"], "zombieTypes", zombie_type),
        ("fact_zombie_instance", ["instance_id"], "zombieInstances", zombie_instance),
    ],
}


# ---------------------------------------------------------------- extract / load

def open_source(name):
    """Returns (client, fetch); fetch(query) -> list of rows as dicts."""
    if name == "zombie":
        client = MongoClient(os.environ["ZOMBIE_DB_URI"], serverSelectionTimeoutMS=5000, tz_aware=True)
        client.admin.command("ping")
        db = client.get_default_database()
        return client, lambda collection: list(db[collection].find())
    dsn = os.environ[f"{name.upper()}_DB_DSN"]
    try:
        conn = connect_read_only(dsn)
    except psycopg.OperationalError:
        # A replicated source is read from a standby (target_session_attrs=standby; psycopg tries each host on its
        # own, so prefer-standby would accept the first one, the primary). With no standby up, any node will do.
        if "target_session_attrs=standby" not in dsn:
            raise
        log("warning", "no_standby", source=name)
        conn = connect_read_only(dsn.replace("target_session_attrs=standby", "target_session_attrs=any"))
    return conn, lambda query: conn.execute(query).fetchall()


def connect_read_only(dsn):
    # default_transaction_read_only: the job can never write to a service database.
    return psycopg.connect(dsn, autocommit=True, connect_timeout=5, row_factory=dict_row,
                           options="-c default_transaction_read_only=on")


def upsert(warehouse, table, keys, rows):
    if not rows:
        return
    cols = list(rows[0])
    query = sql.SQL("INSERT INTO {t} ({c}) VALUES ({v}) ON CONFLICT ({k}) DO UPDATE SET {u}, loaded_at = now()").format(
        t=sql.Identifier(table),
        c=sql.SQL(", ").join(map(sql.Identifier, cols)),
        v=sql.SQL(", ").join(sql.Placeholder(c) for c in cols),
        k=sql.SQL(", ").join(map(sql.Identifier, keys)),
        u=sql.SQL(", ").join(sql.SQL("{c} = EXCLUDED.{c}").format(c=sql.Identifier(c)) for c in cols if c not in keys))
    with warehouse.transaction(), warehouse.cursor() as cur:
        cur.executemany(query, rows)


def run_once():
    with psycopg.connect(os.environ["WAREHOUSE_DSN"], autocommit=True) as warehouse:
        warehouse.execute((Path(__file__).parent / "schema.sql").read_text())
        run_id = warehouse.execute(
            "INSERT INTO etl_runs (started_at, status) VALUES (now(), 'running') RETURNING run_id").fetchone()[0]
        log("info", "etl_run_started", run_id=run_id)
        loaded, errors = {}, []
        for source, jobs in JOBS.items():
            try:
                client, fetch = open_source(source)
            except Exception as e:
                errors.append({"source": source, "error": str(e)})
                log("warning", "source_unavailable", run_id=run_id, source=source, error=str(e))
                continue
            with client:
                for table, keys, query, transform in jobs:
                    try:
                        rows = []
                        for row in fetch(query):
                            out = transform(row)
                            rows.extend(out if isinstance(out, list) else [out])
                        upsert(warehouse, table, keys, rows)
                        loaded[table] = len(rows)
                        log("info", "table_loaded", run_id=run_id, source=source, table=table, rows=len(rows))
                    except Exception as e:
                        errors.append({"source": source, "table": table, "error": str(e)})
                        log("warning", "table_skipped", run_id=run_id, source=source, table=table, error=str(e))
        status = "partial" if errors else "ok"
        warehouse.execute("UPDATE etl_runs SET finished_at = now(), status = %s, rows_loaded = %s, errors = %s "
                          "WHERE run_id = %s", (status, json.dumps(loaded), json.dumps(errors), run_id))
        log("info", "etl_run_finished", run_id=run_id, status=status, rows=loaded, errors=len(errors))


def main():
    interval = int(os.environ.get("ETL_INTERVAL_SECONDS", "300"))
    while True:
        try:
            run_once()
        except Exception as e:  # the warehouse itself is down: try again next time
            log("error", "etl_run_failed", error=str(e))
            if "--once" in sys.argv:
                sys.exit(1)
        if "--once" in sys.argv:
            return
        time.sleep(interval)


if __name__ == "__main__":
    main()
