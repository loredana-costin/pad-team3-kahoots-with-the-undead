# Postman Collections

Collections for testing each service. One file per service, Postman schema v2.1.

| Collection | Service | Default baseUrl |
|---|---|---|
| `player-service.postman_collection.json` | Player Service | `http://localhost:3002` |
| `game-service.postman_collection.json` | Game Service | `http://localhost:3003` |
| `exam-service.postman_collection.json` | Exam Service | `http://localhost:3000` |
| `world-service.postman_collection.json` | World Service | `http://localhost:3001` |
| `zombie-service.postman_collection.json` | Zombie Service | `http://localhost:4001` |
| `resource-service.postman_collection.json` | Resource Service | `http://localhost:4002` |
| `base-service.postman_collection.json` | Base Service | `http://localhost:5003` |
| `crafting-service.postman_collection.json` | Crafting Service | `http://localhost:5004` |

## Running in Postman

1. **Import** -> pick the collection file.
2. Start the service (see its README), then seed its database - see
   [Run Database Seeding](../README.md#2-run-database-seeding).
3. Open the collection, then **Run** to execute every request in order.

The default `baseUrl` values match the host ports in the team `docker-compose.yml`.

The Zombie and Resource collections read seeded records (`prof_calc`, `infected_student`,
`wood`, `node_1`), so they fail on an unseeded database. Seed first.

Requests are numbered and share state through collection variables, so run the whole
collection rather than firing requests individually - later requests depend on ids captured
by earlier ones.

Change `baseUrl` in the collection's **Variables** tab if your service is on another port.

## Running from the command line

```bash
npx newman run postman/player-service.postman_collection.json
npx newman run postman/game-service.postman_collection.json
```

Override the base URL without editing the file:

```bash
npx newman run postman/game-service.postman_collection.json --env-var baseUrl=http://localhost:8080
```

## Re-running

All collections are safe to run repeatedly against the same database. The Player Service
collection randomises usernames per run; the Game Service collection creates its own
sessions each run. The Zombie/Resource Service collections create their own zombie types,
resource types, and idempotency keys per run (via `{{$randomInt}}`/timestamps) — the
"duplicate"/"already_applied" requests are the one deliberate exception, reusing a fixed
key from an earlier request in the same run to prove idempotency. None of these need the
database reset between runs.
