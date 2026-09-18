# Postman Collections

Collections for testing each service. One file per service, Postman schema v2.1.

| Collection | Service | Default baseUrl |
|---|---|---|
| `player-service.postman_collection.json` | Player Service | `http://localhost:5199` |
| `game-service.postman_collection.json` | Game Service | `http://localhost:5299` |
| `exam-service.postman_collection.json` | Exam Service | `http://localhost:3000` |
| `world-service.postman_collection.json` | World Service | `http://localhost:3001` |

## Running in Postman

1. **Import** -> pick the collection file.
2. Start the service (see its README).
3. Open the collection, then **Run** to execute every request in order.

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

Both collections are safe to run repeatedly against the same database. The Player Service
collection randomises usernames per run; the Game Service collection creates its own
sessions each run. Neither needs the database reset between runs.
