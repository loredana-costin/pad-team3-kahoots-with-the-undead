"""Checks the pure transform functions of etl.py. Run: python test_transform.py (or python -m pytest)."""

from datetime import date, datetime, timezone

import etl

T0 = datetime(2026, 11, 23, 10, 0, tzinfo=timezone.utc)
T1 = datetime(2026, 11, 23, 10, 12, 30, tzinfo=timezone.utc)


def test_keys_and_durations():
    assert etl.date_key(T0) == 20261123
    assert etl.date_key(date(2026, 1, 5)) == 20260105
    assert etl.date_key(None) is None
    assert etl.seconds_between(T0, T1) == 750
    assert etl.seconds_between(T0, None) is None


def test_player_keeps_no_pii_and_derives_level():
    row = {"id": "p_1", "username": "veteran", "nickname": "Vet", "group_name": "FAF-231", "xp": 1500,
           "created_on_utc": T0, "email": "veteran@faf.md", "password_hash": "x"}
    out = etl.player(row)
    assert "email" not in out and "password_hash" not in out
    assert out["level"] == 7
    assert etl.player({**row, "xp": 0})["level"] == 1


def test_enums_and_pass_flag():
    session = {"id": "s", "created_on_utc": T0, "zone_id": "z", "status": 2, "player_count": 2,
               "max_players": 4, "cycle_number": 1, "started_at": T0, "finished_at": T1}
    assert etl.game_session(session)["status"] == "finished"
    assert etl.game_session(session)["duration_seconds"] == 750
    attempt = {"id": 1, "started_at": T0, "finished_at": T1, "player_id": "p", "exam_record_id": 3,
               "course_category": "mathematics", "status": "passed", "grade": 90, "correct_count": 9,
               "total_questions": 10}
    assert etl.exam_attempt(attempt)["passed"] is True
    assert etl.exam_attempt({**attempt, "status": "failed"})["passed"] is False


def test_inventory_explodes_into_one_balance_per_resource():
    rows = etl.resource_balances({"player_id": "p", "snapshot_date": date(2026, 11, 23),
                                  "resources": {"wood": 10, "metal": 5}})
    assert sorted((r["resource_type_id"], r["quantity"]) for r in rows) == [("metal", 5), ("wood", 10)]
    assert all(r["snapshot_date_key"] == 20261123 for r in rows)
    assert etl.resource_balances({"player_id": "p", "snapshot_date": date(2026, 11, 23), "resources": {}}) == []


def test_only_gathers_count_as_gathered():
    tx = {"idempotency_key": "k", "player_id": "p", "created_at": T0, "operation": "gather",
          "result": {"status": "applied", "gathered": 4}}
    assert etl.resource_transaction(tx)["amount_gathered"] == 4
    assert etl.resource_transaction({**tx, "operation": "spend"})["amount_gathered"] == 0


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
    print("all transform checks passed")
