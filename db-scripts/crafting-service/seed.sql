-- Crafting Service seed data.
-- Populates the database only when it is empty, so it is safe to run on every start.
-- The schema is created by the service on startup; start the service before running this.

DO $$
BEGIN
    IF to_regclass('public.recipes') IS NULL THEN
        RAISE EXCEPTION 'Crafting Service schema not found. Start crafting-service first so it can create the tables.';
    END IF;

    IF EXISTS (SELECT 1 FROM recipes) THEN
        RAISE NOTICE 'Crafting Service database already has data, seed skipped.';
        RETURN;
    END IF;

    -- The five recipes of the communication contract, one per unlock condition type.
    INSERT INTO recipes (recipe_id, name, output, unlock_type, unlock_min_level, unlock_exam_id, unlock_zone_id, unlock_resource_type, created_at) VALUES
        ('recipe_wood_metal',        'Barricade Kit',     'barricade_kit',     NULL,                 NULL, NULL,                      NULL,              NULL,        now()),
        ('recipe_paper_metal',       'Improvised Weapon', 'improvised_weapon', 'zoneUnlocked',       NULL, NULL,                      'mathematicsWing', NULL,        now()),
        ('recipe_food_chemicals',    'Energy Booster',    'energy_booster',    'resourceDiscovered', NULL, NULL,                      NULL,              'chemicals', now()),
        ('recipe_metal_electronics', 'Zombie Detector',   'zombie_detector',   'playerLevel',        5,    NULL,                      NULL,              NULL,        now()),
        ('recipe_paper_wood',        'Exam Cheat Sheet',  'exam_cheat_sheet',  'examPassed',         NULL, 'discreteMathematicsExam', NULL,              NULL,        now());

    INSERT INTO recipe_ingredients (recipe_id, resource_type, amount, position) VALUES
        ('recipe_wood_metal',        'wood',        3, 0),
        ('recipe_wood_metal',        'metal',       1, 1),
        ('recipe_paper_metal',       'paper',       2, 0),
        ('recipe_paper_metal',       'metal',       2, 1),
        ('recipe_food_chemicals',    'food',        4, 0),
        ('recipe_food_chemicals',    'chemicals',   1, 1),
        ('recipe_metal_electronics', 'metal',       3, 0),
        ('recipe_metal_electronics', 'electronics', 2, 1),
        ('recipe_paper_wood',        'paper',       3, 0),
        ('recipe_paper_wood',        'wood',        1, 1);

    INSERT INTO known_players (player_id, first_seen_at) VALUES
        ('p_44', now()),
        ('player_123', now());

    INSERT INTO player_recipe_unlocks (player_id, recipe_id, unlocked_at) VALUES
        ('p_44', 'recipe_metal_electronics', now()),
        ('p_44', 'recipe_paper_wood', now());

    INSERT INTO craft_attempts (craft_id, idempotency_key, player_id, recipe_id, status, reason, item_delivered, http_status, response_json, created_at, completed_at) VALUES
        ('craft_881', 'craft_p44_barricadekit_001', 'p_44', 'recipe_wood_metal', 'completed', NULL, 'barricade_kit', 200,
         '{"craftId":"craft_881","status":"completed","itemDelivered":"barricade_kit"}', now(), now());

    RAISE NOTICE 'Crafting Service seed data inserted.';
END
$$;
