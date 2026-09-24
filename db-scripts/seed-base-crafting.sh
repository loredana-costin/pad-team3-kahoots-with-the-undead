#!/usr/bin/env bash
# Seeds the Base and Crafting Service databases of the team stack, if they are empty.
# Run from anywhere after `docker compose up -d`; each SQL script skips itself when its tables already hold data.
set -euo pipefail
cd "$(dirname "$0")/.."

wait_for() {
    local name=$1 port=$2
    echo -n "Waiting for $name on :$port "
    for _ in $(seq 1 60); do
        if curl -fs "http://localhost:$port/health" >/dev/null; then echo " up"; return 0; fi
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
wait_for base-service 5003
seed base-db db-scripts/base-service/seed.sql
wait_for crafting-service 5004
seed crafting-db db-scripts/crafting-service/seed.sql
