#!/usr/bin/env bash
# Seeds every service database of the team stack with test data tied to real, loginable players, and writes
# the Postman environment that the "Kahoots Gateway" collection uses (postman/kahoots-local.postman_environment.json).
# Run from anywhere after `docker compose up -d`. Safe to run again: existing data is left alone.
#
# Every API call goes through the Gateway with a Bearer token, like a real client. Reference data that has
# no API (resource inventories, base rooms, crafting recipes, exam history) is written to the databases.
#
#   Player Service   - registers the test users, gives new users XP, items, an achievement and a trade.
#   Resource Service - the image's own seed (resource types, nodes) plus resources for each user.
#   Zombie Service   - the image's own seed (zombie types); instances come from the game's zombie wave.
#   Exam Service     - exams/achievements come from the service; the veteran passed every maths exam.
#   World Service    - zones/rooms/spawn points come from the service (checked only).
#   Base Service     - claimable rooms, a base for each user, and a decoration placed through the API.
#   Crafting Service - the five contract recipes, unlocks for the veteran, and a craft through the API.
#   Game Service     - a lobby and a running session with an action and a zombie wave.
set -euo pipefail
cd "$(dirname "$0")/.."

GATEWAY_URL=${GATEWAY_URL:-http://localhost:8000}
ENV_FILE=postman/kahoots-local.postman_environment.json

# username:password:email:role. The first user is the one the Postman environment logs in as.
USERS=(
    "veteran:veteran123:veteran@faf.md:veteran"
    "trader:trader123:trader@faf.md:trader"
    "survivor:survivor123:survivor@faf.md:player"
    "newbie:newbie123:newbie@faf.md:fresh"
)

# api METHOD PATH [JSON] [JWT] -> prints the body, then the HTTP status on its own last line.
api() {
    local method=$1 path=$2 body=${3:-} jwt=${4:-}
    local args=(-s -X "$method" "$GATEWAY_URL$path" -H "Content-Type: application/json" -w '\n%{http_code}')
    [[ -n "$body" ]] && args+=(-d "$body")
    [[ -n "$jwt" ]] && args+=(-H "Authorization: Bearer $jwt")
    curl "${args[@]}"
}
status_of() { tail -n1 <<< "$1"; }
body_of() { sed '$d' <<< "$1"; }
json_field() { sed -n "s/.*\"$1\":\"\([^\"]*\)\".*/\1/p" <<< "$2" | head -1; }

# expect_ok LABEL RESPONSE -> fails the script unless the response is 2xx.
expect_ok() {
    local code; code=$(status_of "$2")
    if [[ "$code" != 2* ]]; then
        echo "error: $1 failed with $code: $(body_of "$2")" >&2; exit 1
    fi
}

psql_in() {
    docker compose exec -T "$1" sh -c 'psql -v ON_ERROR_STOP=1 -q -At -U "$POSTGRES_USER" -d "$POSTGRES_DB"'
}

echo -n "Waiting for the Gateway at $GATEWAY_URL "
for _ in $(seq 1 60); do
    if [[ "$(status_of "$(api GET /health)")" == "200" ]]; then echo " up"; break; fi
    echo -n "."; sleep 2
done
[[ "$(status_of "$(api GET /health)")" == "200" ]] || { echo; echo "error: the Gateway is not running; start the stack with: docker compose up -d" >&2; exit 1; }

# ---------------------------------------------------------------- Player Service
echo; echo "== Player Service"
declare -A PLAYER_ID JWT ROLE NEW PASSWORD
for entry in "${USERS[@]}"; do
    IFS=: read -r username password email role <<< "$entry"
    # Retried while Player Service is still starting behind the Gateway (502/503).
    for _ in $(seq 1 30); do
        response=$(api POST /api/auth/register "{\"username\":\"$username\",\"password\":\"$password\",\"email\":\"$email\"}")
        [[ "$(status_of "$response")" != 50* ]] && break; sleep 2
    done
    if [[ "$(status_of "$response")" == "200" ]]; then
        NEW[$username]=1
    else
        NEW[$username]=0
        response=$(api POST /api/auth/login "{\"username\":\"$username\",\"password\":\"$password\"}")
        expect_ok "logging in as $username" "$response"
    fi
    PLAYER_ID[$username]=$(json_field player_id "$(body_of "$response")")
    JWT[$username]=$(json_field jwt "$(body_of "$response")")
    ROLE[$username]=$role
    PASSWORD[$username]=$password
    echo "  $username -> ${PLAYER_ID[$username]} ($([[ ${NEW[$username]} == 1 ]] && echo registered || echo already existed))"
done

# Every service must answer through the Gateway before anything is written.
for path in /api/sessions /api/resource-types /api/zombie-types "/api/base?skip=0&take=1" /api/recipes/recipe_wood_metal /exams /world/zones; do
    for _ in $(seq 1 30); do
        [[ "$(status_of "$(api GET "$path" "" "${JWT[veteran]}")")" != 50* ]] && break; sleep 2
    done
done

# XP and items stack on every call, so they are only given to users registered by this run.
player_call() {
    local username=$1 method=$2 path=$3 body=$4
    expect_ok "$method $path for $username" \
        "$(api "$method" "/api/players/${PLAYER_ID[$username]}$path" "$body" "${JWT[$username]}")"
}
add_item() { player_call "$1" POST /inventory/items "{\"itemId\":\"$2\",\"quantity\":$3,\"source\":\"seed\"}"; }

for username in "${!PLAYER_ID[@]}"; do
    [[ ${NEW[$username]} == 1 ]] || continue
    case ${ROLE[$username]} in
        player)
            player_call "$username" PATCH /progression '{"xpDelta":300,"reason":"seed"}'
            add_item "$username" coffee 3
            add_item "$username" energy_drink 1
            ;;
        trader)
            player_call "$username" PATCH /progression '{"xpDelta":150,"reason":"seed"}'
            add_item "$username" sandwich 4
            add_item "$username" coffee 1
            add_item "$username" cosmetic_cap 1
            ;;
        veteran)
            player_call "$username" PATCH /progression '{"xpDelta":1500,"reason":"seed"}'
            add_item "$username" coffee 5
            add_item "$username" barricade_kit 2
            add_item "$username" energy_booster 1
            player_call "$username" POST /achievements \
                '{"achievementId":"achievementSurvivedMathematics","grantedBy":"exam:mathematics_complete"}'
            ;;
    esac
done

# Trades are idempotent by key, so replaying this returns the same trade.
response=$(api POST /api/trades "{\"idempotencyKey\":\"seed_trade_veteran_trader\",\"fromPlayerId\":\"${PLAYER_ID[veteran]}\",\"toPlayerId\":\"${PLAYER_ID[trader]}\",\"offer\":[{\"itemId\":\"coffee\",\"qty\":1}],\"request\":[{\"itemId\":\"sandwich\",\"qty\":1}]}" "${JWT[veteran]}")
expect_ok "the seed trade" "$response"
TRADE_ID=$(json_field tradeId "$(body_of "$response")")
echo "  progression, inventory, achievements and trade $TRADE_ID ensured"

# SQL value list of the seeded players by role, e.g. ('p_1','player'),('p_2','trader').
values=""
for username in "${!PLAYER_ID[@]}"; do
    values+="${values:+,}('${PLAYER_ID[$username]}','${ROLE[$username]}')"
done

# ---------------------------------------------------------------- Resource Service
echo; echo "== Resource Service"
docker compose exec -T resource-service node dist/scripts/seed.js
psql_in resource-db <<SQL
INSERT INTO inventories (player_id, resources)
SELECT id, CASE role
    WHEN 'player'  THEN '{"wood":10,"metal":5,"food":8,"paper":4}'
    WHEN 'trader'  THEN '{"wood":4,"metal":2,"food":20,"paper":6}'
    WHEN 'veteran' THEN '{"wood":30,"metal":20,"food":25,"paper":15,"chemicals":6,"electronics":8}'
    ELSE '{}' END::jsonb
FROM (VALUES $values) AS seeded(id, role)
ON CONFLICT (player_id) DO NOTHING;
SQL
echo "  inventories ensured"

# ---------------------------------------------------------------- Zombie Service
echo; echo "== Zombie Service"
docker compose exec -T zombie-service node dist/scripts/seed.js

# ---------------------------------------------------------------- Exam Service
echo; echo "== Exam Service"
psql_in exam-db <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM exams) THEN
        RAISE EXCEPTION 'Exam Service has no exams; it seeds them on startup, so check that exam-service is running.';
    END IF;
END
\$\$;

-- The veteran has passed every mathematics exam, which is what unlocks the mathematics achievement.
INSERT INTO attempts (player_id, exam_record_id, course_category, zombie_encounter_id, status, answers, grade, correct_count, total_questions, started_at, finished_at)
SELECT seeded.id, e.id, e.course_category, 'seed_encounter_' || e.id, 'passed',
       (SELECT jsonb_object_agg(q->>'id', (q->>'correctOptionId')::int) FROM jsonb_array_elements(e.questions) q),
       100, jsonb_array_length(e.questions), jsonb_array_length(e.questions),
       now() - interval '1 day', now() - interval '1 day' + interval '10 minutes'
FROM (VALUES $values) AS seeded(id, role)
JOIN exams e ON e.course_category = 'mathematics'
WHERE seeded.role = 'veteran'
  AND NOT EXISTS (SELECT 1 FROM attempts a WHERE a.player_id = seeded.id AND a.exam_record_id = e.id);

INSERT INTO player_achievements (player_id, achievement_record_id)
SELECT seeded.id, a.id
FROM (VALUES $values) AS seeded(id, role)
JOIN achievements a ON a.condition = 'allExamsPassed:mathematics'
WHERE seeded.role = 'veteran'
  AND NOT EXISTS (SELECT 1 FROM player_achievements pa WHERE pa.player_id = seeded.id AND pa.achievement_record_id = a.id);
SQL
EXAM_ID=$(psql_in exam-db <<< "SELECT min(id) FROM exams WHERE course_category = 'mathematics'")
ATTEMPT_ID=$(psql_in exam-db <<< "SELECT min(id) FROM attempts WHERE player_id = '${PLAYER_ID[veteran]}'")
echo "  $(psql_in exam-db <<< 'SELECT count(*) FROM exams') exams; veteran attempts and achievement ensured"

# ---------------------------------------------------------------- World Service
echo; echo "== World Service"
echo "  $(psql_in world-db <<< "SELECT (SELECT count(*) FROM zones) || ' zones, ' || (SELECT count(*) FROM rooms) || ' rooms, ' || (SELECT count(*) FROM spawn_points) || ' spawn points'") (seeded by the service on startup)"
SPAWN_POINT_ID=$(psql_in world-db <<< "SELECT min(id) FROM spawn_points")
unlocked_rooms=$(psql_in world-db <<< "SELECT string_agg(format('(%L,%L)', r.room_name, z.zone_name), ',') FROM rooms r JOIN zones z ON z.id = r.zone_record_id WHERE z.unlocked")

# ---------------------------------------------------------------- Base Service
echo; echo "== Base Service"
psql_in base-db <<SQL
INSERT INTO claimable_rooms (room_id, zone_id, unlocked_at)
SELECT room_id, zone_id, now() FROM (VALUES ${unlocked_rooms:-('mainCorridor','mainCorridorZone')}) AS r(room_id, zone_id)
ON CONFLICT (room_id) DO NOTHING;

WITH new_bases AS (
    INSERT INTO bases (player_id, kiki_mood, kiki_cooldown_until, created_at)
    SELECT id, CASE role WHEN 'veteran' THEN 'happy' ELSE 'content' END, NULL, now()
    FROM (VALUES $values) AS seeded(id, role)
    WHERE role <> 'fresh'
    ON CONFLICT (player_id) DO NOTHING
    RETURNING player_id
), roles AS (
    SELECT nb.player_id, s.role FROM new_bases nb JOIN (VALUES $values) AS s(id, role) ON s.id = nb.player_id
), rooms AS (
    INSERT INTO base_rooms (player_id, room_id, barricade_level, claimed_at)
    SELECT player_id, 'faf_cab', CASE role WHEN 'veteran' THEN 3 WHEN 'player' THEN 1 ELSE 0 END, now() FROM roles
    UNION ALL
    SELECT player_id, 'library', 1, now() FROM roles WHERE role = 'veteran'
    RETURNING 1
)
INSERT INTO facilities (player_id, facility_type, level)
SELECT player_id, 'storage', CASE role WHEN 'veteran' THEN 2 ELSE 1 END FROM roles
UNION ALL
SELECT player_id, 'workshop', 1 FROM roles WHERE role = 'veteran';
SQL
response=$(api POST "/api/base/${PLAYER_ID[veteran]}/decorations" \
    '{"idempotencyKey":"seed_decorate_veteran_faf_poster","itemId":"faf_poster","roomId":"faf_cab"}' "${JWT[veteran]}")
expect_ok "placing the seed decoration" "$response"
DECORATION_ID=$(json_field decorationId "$(body_of "$response")")
echo "  bases ensured for every user except newbie; decoration $DECORATION_ID"

# ---------------------------------------------------------------- Crafting Service
echo; echo "== Crafting Service"
psql_in crafting-db <<SQL
-- The five recipes of the communication contract, one per unlock condition type.
WITH new_recipes AS (
    INSERT INTO recipes (recipe_id, name, output, unlock_type, unlock_min_level, unlock_exam_id, unlock_zone_id, unlock_resource_type, created_at) VALUES
        ('recipe_wood_metal',        'Barricade Kit',     'barricade_kit',     NULL,                 NULL, NULL,                      NULL,              NULL,        now()),
        ('recipe_paper_metal',       'Improvised Weapon', 'improvised_weapon', 'zoneUnlocked',       NULL, NULL,                      'mathematicsWing', NULL,        now()),
        ('recipe_food_chemicals',    'Energy Booster',    'energy_booster',    'resourceDiscovered', NULL, NULL,                      NULL,              'chemicals', now()),
        ('recipe_metal_electronics', 'Zombie Detector',   'zombie_detector',   'playerLevel',        5,    NULL,                      NULL,              NULL,        now()),
        ('recipe_paper_wood',        'Exam Cheat Sheet',  'exam_cheat_sheet',  'examPassed',         NULL, 'discreteMathematicsExam', NULL,              NULL,        now())
    ON CONFLICT (recipe_id) DO NOTHING
    RETURNING recipe_id
)
INSERT INTO recipe_ingredients (recipe_id, resource_type, amount, position)
SELECT i.recipe_id, i.resource_type, i.amount, i.position
FROM (VALUES
    ('recipe_wood_metal',        'wood',        3, 0),
    ('recipe_wood_metal',        'metal',       1, 1),
    ('recipe_paper_metal',       'paper',       2, 0),
    ('recipe_paper_metal',       'metal',       2, 1),
    ('recipe_food_chemicals',    'food',        4, 0),
    ('recipe_food_chemicals',    'chemicals',   1, 1),
    ('recipe_metal_electronics', 'metal',       3, 0),
    ('recipe_metal_electronics', 'electronics', 2, 1),
    ('recipe_paper_wood',        'paper',       3, 0),
    ('recipe_paper_wood',        'wood',        1, 1)
) AS i(recipe_id, resource_type, amount, position)
JOIN new_recipes USING (recipe_id);

INSERT INTO known_players (player_id, first_seen_at)
SELECT id, now() FROM (VALUES $values) AS seeded(id, role)
ON CONFLICT (player_id) DO NOTHING;

-- The veteran is level 7 and passed the mathematics exams, so the level and exam recipes are open.
INSERT INTO player_recipe_unlocks (player_id, recipe_id, unlocked_at)
SELECT seeded.id, r.recipe_id, now()
FROM (VALUES $values) AS seeded(id, role)
CROSS JOIN (VALUES ('recipe_metal_electronics'), ('recipe_paper_wood')) AS r(recipe_id)
WHERE seeded.role = 'veteran'
ON CONFLICT (player_id, recipe_id) DO NOTHING;
SQL
response=$(api POST /api/craft \
    "{\"idempotencyKey\":\"seed_craft_veteran_barricade_kit\",\"playerId\":\"${PLAYER_ID[veteran]}\",\"recipeId\":\"recipe_wood_metal\"}" "${JWT[veteran]}")
expect_ok "the seed craft" "$response"
CRAFT_ID=$(json_field craftId "$(body_of "$response")")
echo "  recipes, known players and unlocks ensured; craft $CRAFT_ID"

# ---------------------------------------------------------------- Game Service
echo; echo "== Game Service"
session_named() { psql_in game-db <<< "SELECT id FROM game_sessions WHERE name = '$1' ORDER BY created_on_utc LIMIT 1"; }

# ensure_session NAME start|lobby USER... -> prints the session id, creating the session when it is missing.
ensure_session() {
    local name=$1 start=$2; shift 2
    local id response
    id=$(session_named "$name")
    if [[ -n "$id" ]]; then echo "$id"; return; fi
    response=$(api POST /api/sessions "{\"name\":\"$name\",\"zoneId\":\"mainCorridorZone\",\"maxPlayers\":4}" "${JWT[veteran]}")
    expect_ok "creating '$name'" "$response"
    id=$(json_field session_id "$(body_of "$response")")
    for username in "$@"; do
        expect_ok "joining $username to '$name'" \
            "$(api POST "/api/sessions/$id/players" "{\"playerId\":\"${PLAYER_ID[$username]}\"}" "${JWT[$username]}")"
    done
    if [[ "$start" == "start" ]]; then
        expect_ok "starting '$name'" "$(api POST "/api/sessions/$id/start" "" "${JWT[veteran]}")"
        # A short action, so it completes and shows a real gather result.
        expect_ok "the seed action" "$(api POST "/api/sessions/$id/actions" \
            "{\"playerId\":\"${PLAYER_ID[veteran]}\",\"actionType\":\"scavenge\",\"targetNodeId\":\"node_3\",\"durationSeconds\":5}" "${JWT[veteran]}")"
    fi
    echo "$id"
}

LOBBY_ID=$(ensure_session "Seed Lobby" lobby survivor trader)
SESSION_ID=$(ensure_session "Seed Running Session" start veteran survivor)
ACTION_ID=$(psql_in game-db <<< "SELECT id FROM player_actions WHERE session_id = '$SESSION_ID' ORDER BY created_on_utc LIMIT 1")
# Spawning again in the same cycle returns the same wave, so this is safe to repeat.
response=$(api POST "/api/sessions/$SESSION_ID/zombies/spawn" '{"typeWeights":{"professor":1}}' "${JWT[veteran]}")
expect_ok "the seed zombie wave" "$response"
ZOMBIE_INSTANCE_ID=$(json_field instanceId "$(body_of "$response")")
echo "  lobby $LOBBY_ID, running session $SESSION_ID, action ${ACTION_ID:-none}, zombie $ZOMBIE_INSTANCE_ID"

# ---------------------------------------------------------------- Postman environment
env_value() { printf '    { "key": "%s", "value": "%s", "type": "%s", "enabled": true }
' "$1" "$2" "${3:-default}"; }
{
    echo '{'
    echo '  "id": "6b0f6a52-6a4e-4f4e-9d65-0b6f2c1d7a10",'
    echo '  "name": "Kahoots Local (seeded)",'
    echo '  "values": ['
    {
        env_value gatewayUrl "$GATEWAY_URL"
        env_value username veteran
        env_value password "${PASSWORD[veteran]}" secret
        env_value jwt "${JWT[veteran]}" secret
        env_value playerId "${PLAYER_ID[veteran]}"
        env_value playerBId "${PLAYER_ID[trader]}"
        env_value survivorId "${PLAYER_ID[survivor]}"
        env_value newbieId "${PLAYER_ID[newbie]}"
        env_value tradeId "$TRADE_ID"
        env_value sessionId "$SESSION_ID"
        env_value lobbyId "$LOBBY_ID"
        env_value actionId "$ACTION_ID"
        env_value zombieInstanceId "$ZOMBIE_INSTANCE_ID"
        env_value gameExamAttemptId ""
        env_value examId "$EXAM_ID"
        env_value attemptId "$ATTEMPT_ID"
        env_value zoneName mathematicsWing
        env_value roomName physicsLaboratory
        env_value spawnPointId "$SPAWN_POINT_ID"
        env_value resourceTypeId wood
        env_value nodeId node_1
        env_value zombieTypeId prof_calc
        env_value recipeId recipe_wood_metal
        env_value craftId "$CRAFT_ID"
        env_value decorationId "$DECORATION_ID"
        # Filled by the "Create ..." requests, so the update/delete requests never touch seeded data.
        for key in createdPlayerId createdSessionId createdActionId createdExamId createdZoneName createdRoomName createdSpawnPointId \
                   createdResourceTypeId createdInventoryPlayerId createdZombieTypeId createdDecorationId createdRecipeId; do
            env_value "$key" ""
        done
    } | paste -sd ',' - | sed 's/,    {/,\n    {/g'
    echo '  ],'
    echo '  "_postman_variable_scope": "environment"'
    echo '}'
} > "$ENV_FILE"

cat <<EOF

Done. Postman environment written to $ENV_FILE
Import it together with postman/kahoots-gateway.postman_collection.json and select "Kahoots Local (seeded)".

Test users (POST $GATEWAY_URL/api/auth/login):

  username   password     player id        what they have
  ---------  -----------  ---------------  ------------------------------------------------------
  veteran    veteran123   $(printf '%-15s' "${PLAYER_ID[veteran]}")  level 7, maths exams passed + achievement, crafting unlocks, base, craft, trade
  trader     trader123    $(printf '%-15s' "${PLAYER_ID[trader]}")  sandwiches to trade, food-heavy resources, base, in the lobby
  survivor   survivor123  $(printf '%-15s' "${PLAYER_ID[survivor]}")  some XP, coffee, basic resources, base, in both sessions
  newbie     newbie123    $(printf '%-15s' "${PLAYER_ID[newbie]}")  brand new: no items, no resources, no base
EOF
