#!/usr/bin/env bash
# Seeds the Base and Crafting Service databases of the team stack, if they are empty.
# Run from anywhere after `docker compose up -d`; each SQL script skips itself when its tables already hold data.
set -euo pipefail
cd "$(dirname "$0")/.."

# The services are reachable only through the Gateway, so readiness is read from their databases:
# the seed can run once the service has created the table its script checks.
wait_for() {
    local name=$1 db=$2 table=$3
    echo -n "Waiting for $name to create its tables "
    for _ in $(seq 1 60); do
        if docker compose exec -T "$db" sh -c "psql -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc \"SELECT to_regclass('public.$table')\"" 2>/dev/null | grep -qx "$table"; then
            echo " up"; return 0
        fi
        echo -n "."; sleep 2
    done
    echo; echo "error: $name is not running; start it with: docker compose up -d $name" >&2; exit 1
}

seed() {
    local db=$1 script=$2
    echo "Seeding $db from $script"
    docker compose exec -T "$db" sh -c 'psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB"' < "$script"
}

# The services create their tables on startup, so they must be up before the data goes in.
wait_for base-service base-db bases
seed base-db db-scripts/base-service/seed.sql
wait_for crafting-service crafting-db recipes
seed crafting-db db-scripts/crafting-service/seed.sql
