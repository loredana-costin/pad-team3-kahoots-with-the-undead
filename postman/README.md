# Postman Collections

Collections for testing each service. One file per service, Postman schema v2.1.

| Collection | Service | Default baseUrl |
|---|---|---|
| `player-service.postman_collection.json` | Player Service | `http://localhost:8000` |
| `game-service.postman_collection.json` | Game Service | `http://localhost:8000` |
| `exam-service.postman_collection.json` | Exam Service | `http://localhost:8000` |
| `world-service.postman_collection.json` | World Service | `http://localhost:8000/world` |
| `zombie-service.postman_collection.json` | Zombie Service | `http://localhost:8000` |
| `resource-service.postman_collection.json` | Resource Service | `http://localhost:8000` |
| `base-service.postman_collection.json` | Base Service | `http://localhost:8000` |
| `crafting-service.postman_collection.json` | Crafting Service | `http://localhost:8000` |
| `message-broker.postman_collection.json` | Message Broker | `http://localhost:8600` |

## Running in Postman

1. **Import** -> pick the collection file.
2. Start the service (see its README), then seed its database - see
   [Run Database Seeding](../README.md#2-run-database-seeding).
3. Open the collection, then **Run** to execute every request in order.

The default `baseUrl` values match the host ports in the team `docker-compose.yml`.

The Exam and World collections also exercise endpoints that only a service may call
(`POST /exams/start`, `/exams/{attemptId}/submit`, `/exams/{attemptId}/abandon`,
`GET /exams/{examId}/retryEligibility`, `POST /world/zones/unlock`). They mint a service
token in the "Service token (Game Service)" request, signed with the collection variable
`jwtSecret`. It defaults to the team compose development secret and must equal the Gateway's
`JWT_SECRET`; change it if your stack uses another one.

Two World requests go straight to a World Service instance instead of the Gateway,
`GET /health` and `POST /events/exam-passed`, using the variable `worldDirectUrl`
(`http://localhost:3001`). The team compose does not publish that port, so publish it
temporarily or those two requests will fail to connect. `POST /events/exam-passed` answers
`404` until the World team implements it, which the collection accepts.

The Player and Game collections deliver their events through the message broker, since the
Gateway no longer forwards the service-only `/api/players/events` and `/api/sessions/events`
routes: they publish on a topic (`POST {{brokerUrl}}/topics/ExamPassed/publish`,
`POST {{brokerUrl}}/topics/ZoneUnlocked/publish`) with a service token minted from `jwtSecret`,
the broker delivers the event to the subscribed service, and the next request reads the effect
back through the Gateway. `brokerUrl` defaults to `http://localhost:8600`, which the team compose
publishes.

The Message Broker collection (`message-broker.postman_collection.json`) verifies all 7 Message Broker tasks
running on port `8600` (with every assertion labeled `[SUCCESS] ...` or `[EXPECTED REJECTION] ...` in the Test Results tab):
- **Folder 0 (Setup & Token Minting)**: Health check and dynamic HMAC-SHA256 JWT minting for both service tokens (`kind: "service"`) and player tokens (`kind: "player"`).
- **Folder 1 (Task 1 - Logs Download)**: Exercises `GET /logs/download` testing full download, `tail=50`, `since` timestamp filtering, and security gates (`401 missing_admin_key`, `403 invalid_admin_key`).
- **Folder 2 (Task 2 - Service-to-Service Relay)**: Verifies `ANY /relay/{serviceName}/{path}`, testing service token authentication, anti-spoofing header stripping (`X-Service-Name`), `401` on missing token, `403` on player token, and `400` on path traversal and self-relay loops.
- **Folder 3 (Task 2 & 7 - Load Balancing, Circuit Breakers & High Availability)**: Checks Service Discovery connectivity, verifies Load-Aware Round-Robin rotation, Circuit Breaker state transitions (`CLOSED` -> `OPEN` -> `HALF_OPEN` -> `CLOSED`), and High-Availability rerouting.
- **Folder 4 (Task 3 - Subscriber Queues)**: Exercises `ANY /queues/{serviceName}/{path}` (`X-Broker-Queue` header, active consumer threads in `/health`, `401` and `400` rejections).
- **Folder 5 (Task 3 & 4 - Topic-Based Queues & GET /topics)**: Publishes events to `POST /topics/{topic}/publish` (`202 Accepted`), fetches the registered topics from `GET /topics`, and verifies `400`/`401` rejections.
- **Folder 6 (Task 4 - Thread-per-Request Architecture)**: Proves consecutive requests execute on distinct OS worker threads (`X-Broker-Thread: req-xxxx`) and inspects thread pool statistics in `/health`.
- **Folder 7 (Task 5 - gRPC Service-to-Service Communication)**: Verifies the gRPC server is active on port `8601` and `broker_grpc_calls_total` is exported.
- **Folder 8 (Task 6 - Durable Queues & Dead Letter Channel)**: Publishes an unsendable event to trigger the SQLite-backed Dead Letter Channel, fetches dead letters via `GET /dead-letters` (and filtered via `?topic=DeadLetterDemo&limit=5`), and tests `401`/`400` error gates.
- **Folder 9 (Task 7 - Prometheus & Grafana/Loki Observability)**: Scrapes `GET /metrics` for HTTP, dispatch, circuit breaker, HA reroute, in-flight load, thread pool, and durable message store gauges, and verifies structured JSON logs with correlation `requestId`s.

The Base and Crafting collections use the broker the same way. Their setup credits the test player
through Resource Service's `POST /api/refund`, which the Gateway refuses, so it goes to the broker's
queue instead (`POST {{brokerUrl}}/queues/resource-service/api/refund`) with a service token minted
from `jwtSecret`. Both publish `ZoneUnlocked` on the broker and check that their service is among the
subscribers; the Base collection then claims the room the event opened. Their last request downloads
the service's logs through the Gateway (`/api/base/logs/download`, `/api/crafts/logs/download`) with
`X-Admin-Key: {{logsAdminKey}}`: set `logsAdminKey` to the stack's `LOGS_ADMIN_KEY` to get the file,
or leave it empty to check that the download is refused.

The Zombie and Resource collections read seeded records (`prof_calc`, `infected_student`,
`wood`, `node_1`), so they fail on an unseeded database. Seed first.

The Zombie and Resource collections also call the routes only the services use, which the Gateway
refuses with `404 route_not_found`: `POST /api/zombies/spawn` and `POST /api/zombies/{id}/special-action`
(Game Service), `POST /api/inventory/{playerId}` and `POST /api/gather` (Game Service), `POST /api/spend`
and `POST /api/refund` (Base and Crafting Service). For each, one request checks that the Gateway refuses
it, and the real requests go to the service's queue in the broker
(`POST {{brokerUrl}}/queues/zombie-service/api/zombies/spawn`, `.../queues/resource-service/api/gather`, ...)
with a token of the service that calls the route, minted from `jwtSecret` like the Base and Crafting
collections do; each checks the broker's `X-Broker-Queue` and `X-Broker-Instance` headers. Their last
folder, **Monitoring**, reads `GET /metrics` of one replica through the broker's queue (what Prometheus
scrapes; the team compose does not publish the services' ports) and checks that the Gateway does not
expose it.

The Zombie collection's **Two-Phase Commit (the Gateway as coordinator)** folder runs the transactions the Gateway
coordinates across Zombie and Resource Service, and needs the Gateway, Zombie Service and Resource Service **5.0.0**
images or later (the team compose still runs 4.0.0, where these requests fail). It:

- spawns two Infected Zombies and a Tourist Zombie through the broker;
- gives the test player exactly the spawned type's cure requirement;
- cures one zombie (`200`, both participants committed), then checks the inventory and each participant's side
  through the broker (`GET {{brokerUrl}}/queues/{service}/api/tx/{{txId}}`);
- checks the aborts: `already_cured`, `insufficient_resources` with the zombie released, `not_a_tourist`, and stealing
  more than the player has;
- checks a committed steal, `400` invalid loot, `404` for an unknown transaction, and that the participants'
  `/api/tx/...` endpoints are not reachable through the Gateway.

The Zombie collection's **Sagas (the Message Broker as coordinator)** folder runs the same two actions as
long-running sagas, and also needs the **5.0.0** images or later. It starts them on the broker
(`POST {{brokerUrl}}/sagas` with a service token), so it works whatever the Gateway's `COORDINATION_MODE` is; with
`COORDINATION_MODE=saga`, `POST /api/zombies/{id}/cure` and `/steal` on the Gateway start the same sagas. It:

- spawns two Infected Zombies and a Tourist Zombie, and gives the player exactly the cure requirement;
- runs a cure that completes, checked through the Gateway (`GET {{baseUrl}}/api/sagas/{sagaId}`), in the inventory
  and in the broker (the first step's answer fed the second);
- runs a cure the player can't pay for, which is compensated (the cure undone);
- runs a steal that completes, and a steal by a zombie that isn't a Tourist, which is compensated (the food refunded);
- lists the compensated sagas, and checks `400` for an unknown saga, `404` for an unknown saga id, and that the saga
  step routes (`/api/zombies/{id}/saga/...`) are not reachable through the Gateway.

Each request that reads a saga's outcome waits 1.5 s first, as the saga runs in the broker after it was started.

The Zombie and Resource collections' **Cache (Redis, sharded with consistent hashing)** folders check the Redis cache,
and need the **5.0.0** images or later. The Zombie folder uses a zombie type it creates, and the Resource folder an
inventory it creates. Each folder:

- reads it twice: `X-Cache: MISS`, then `HIT` from the same node (`X-Cache-Node`, chosen by the consistent-hashing
  ring), with the Gateway's `X-Auth-Cache: HIT` for the already verified token;
- changes it (`PUT`), then checks that the next read is a `MISS` with the new value, never the cached one, and the one
  after it a `HIT`;
- deletes it and checks the `404`.

The Zombie and Resource collections' **Replication and failover** folders read one replica's `GET /status` and
`GET /metrics` through the broker's queue. They check that the database has 3 nodes, exactly one of them the primary,
the others `secondary` (MongoDB) or `standby` (PostgreSQL), and that `kahoots_database_has_primary` is 1. They need the
**5.0.0** images; with 4.0.0 the checks are skipped. To see a failover, stop the primary (see the main README,
"Database replication and failover") and run the folder again: another node is the primary.

The cache headers are only sent with `CACHE_DEBUG_HEADERS=true` in `.env`. Without them, the cache checks show as
skipped and only the answers are checked.

The Player and Game collections cover lab 5 for Player and Game Service, and need their **5.0.0** images or later.
The Player collection:

- sends its service-only requests (progression, items, achievements, and the ones below) through the message broker's
  relay (`{{brokerUrl}}/relay/player-service/...`) with a service token, since the Gateway refuses those routes;
- logs in and reads the profile twice, expecting `X-Cache: HIT` the second time (with `CACHE_DEBUG_HEADERS=true`);
- runs the room-clearing Two-Phase Commit's participant steps: prepare (votes `commit`), commit, commit again
  (idempotent), the inventory read after it (the cache was invalidated), an abort after the commit (`409`), and a
  prepare for an unknown player (votes `abort`);
- runs the `clear-room` saga's grant, grant again, revoke, and a revoke that arrives before its grant, after which
  the late grant is refused (`409 step_cancelled`);
- checks that the Gateway refuses the participant routes (`404 route_not_found`).

The Game collection's last requests clear rooms in a fresh session, with the player of the collection's token and
`p_ghost`, whom Player Service doesn't know:

- a Two-Phase Commit that commits (the loot in the response, the transaction log, and the player's inventory), and
  one that aborts (`409 transaction_aborted`, `player_not_found`, the action still in progress);
- the `clear-room` saga started on the broker directly with Game Service's service token, which is what Game Service
  does itself with `GAME_COORDINATION_MODE=saga`: one completes, followed through the Gateway's `GET /api/sagas/{id}`,
  and the one for `p_ghost` is compensated (the action reopened);
- that the Gateway refuses the saga step routes.

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
