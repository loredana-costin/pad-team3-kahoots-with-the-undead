-- Base Service seed data.
-- Populates the database only when it is empty, so it is safe to run on every start.
-- The schema is created by the service on startup; start the service before running this.

DO $$
BEGIN
    IF to_regclass('public.bases') IS NULL THEN
        RAISE EXCEPTION 'Base Service schema not found. Start base-service first so it can create the tables.';
    END IF;

    IF EXISTS (SELECT 1 FROM bases) THEN
        RAISE NOTICE 'Base Service database already has data, seed skipped.';
        RETURN;
    END IF;

    INSERT INTO bases (player_id, kiki_mood, kiki_cooldown_until, created_at) VALUES
        ('p_44', 'content', NULL, now()),
        ('p_45', 'happy', now() + interval '2 hours', now()),
        ('player_123', 'content', NULL, now());

    INSERT INTO base_rooms (player_id, room_id, barricade_level, claimed_at) VALUES
        ('p_44', 'faf_cab', 2, now()),
        ('p_44', 'mainCorridor', 0, now()),
        ('p_45', 'faf_cab', 1, now()),
        ('player_123', 'faf_cab', 0, now());

    INSERT INTO facilities (player_id, facility_type, level) VALUES
        ('p_44', 'storage', 2),
        ('p_45', 'workshop', 1);

    INSERT INTO decorations (decoration_id, player_id, item_id, room_id, morale_bonus, placed_at) VALUES
        ('dec_01', 'p_44', 'faf_poster', 'faf_cab', 3, now()),
        ('dec_02', 'p_45', 'string_lights', 'faf_cab', 2, now());

    INSERT INTO base_transactions (idempotency_key, player_id, action, status, reward_item_id, http_status, response_json, created_at, completed_at) VALUES
        ('barricade_p44_faf_cab_001', 'p_44', 'barricade', 'completed', NULL, 200,
         '{"roomId":"faf_cab","barricadeLevel":2,"defenseRating":34,"resourcesSpent":{"wood":5,"metal":2}}', now(), now()),
        ('kiki_p45_001', 'p_45', 'kiki', 'completed', 'energy_booster', 200,
         '{"mood":"happy","reward":{"itemId":"energy_booster","quantity":1},"resourcesSpent":{"food":5}}', now(), now());

    RAISE NOTICE 'Base Service seed data inserted.';
END
$$;
