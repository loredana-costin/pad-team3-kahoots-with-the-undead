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
| `kahoots-gateway.postman_collection.json` | Every service, through the Gateway | `gatewayUrl` in `kahoots-local.postman_environment.json` |

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
`JWT_SECRET`; change it if your stack uses another one. The World request that tries
`POST /world/zones/unlock` with a player token through the Gateway expects it refused: `404
route_not_found` from the Gateway (which keeps the route internal), or `403` from World Service.

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

The Kahoots Gateway collection (`kahoots-gateway.postman_collection.json`) calls every service through the Gateway
with the seeded veteran's token, using the environment that `bash db-scripts/seed-all.sh` writes. For the routes only
the services call (XP, items, achievements, event deliveries, exam encounters, spawning, gathering, spending, refunds,
base actions, and every Two-Phase Commit and saga step), it checks that the Gateway refuses them with
`404 route_not_found`; the per-service collections call them through the broker. It also:

- cures and robs with the seeded zombie through the Gateway's Two-Phase Commit (`POST /api/zombies/{id}/cure` and
  `/steal`): `200` committed, or `409 transaction_aborted` with the reason (the seeded zombie's type decides which),
  or `202` with the saga under `COORDINATION_MODE=saga`;
- reads the transaction back (`GET /api/tx/{txId}`), and checks `400 invalid_body`, `404 tx_not_found` and
  `404 saga_not_found`;
- reads the seeded action's room-clearing transaction (`GET /api/actions/{id}/transaction`, `404` until a room is
  cleared).

The Message Broker collection (`message-broker.postman_collection.json`) verifies the Message Broker tasks
running on port `8600` (with every assertion labeled `[SUCCESS] ...` or `[EXPECTED REJECTION] ...` in the Test Results tab).
The log downloads need `LOGS_ADMIN_KEY` in `.env` to equal the collection variable `logsAdminKey`.
- **Folder 0 (Setup & Token Minting)**: Health check and dynamic HMAC-SHA256 JWT minting for both service tokens (`kind: "service"`) and player tokens (`kind: "player"`). `GET /status` also checks where the message and saga stores are kept (`database`) and, with the replicated store, that `broker-db-1..3` have exactly one primary and the others are `standby`.
- **Folder 1 (Task 1 - Logs Download)**: Exercises `GET /logs/download` testing full download, `tail=50`, `since` timestamp filtering, and security gates (`401 missing_admin_key`, `403 invalid_admin_key`).
- **Folder 2 (Task 2 - Service-to-Service Relay)**: Verifies `ANY /relay/{serviceName}/{path}`, testing service token authentication, anti-spoofing header stripping (`X-Service-Name`), `401` on missing token, `403` on player token, and `400` on path traversal and self-relay loops.
- **Folder 3 (Task 2 & 7 - Load Balancing, Circuit Breakers & High Availability)**: Checks Service Discovery connectivity, verifies Load-Aware Round-Robin rotation, Circuit Breaker state transitions (`CLOSED` -> `OPEN` -> `HALF_OPEN` -> `CLOSED`), and High-Availability rerouting.
- **Folder 4 (Task 3 - Subscriber Queues)**: Exercises `ANY /queues/{serviceName}/{path}` (`X-Broker-Queue` header, active consumer threads in `/health`, `401` and `400` rejections).
- **Folder 5 (Task 3 & 4 - Topic-Based Queues & GET /topics)**: Publishes events to `POST /topics/{topic}/publish` (`202 Accepted`), fetches the registered topics from `GET /topics`, and verifies `400`/`401` rejections.
- **Folder 6 (Task 4 - Thread-per-Request Architecture)**: Proves consecutive requests execute on distinct OS worker threads (`X-Broker-Thread: req-xxxx`) and inspects thread pool statistics in `/health`.
- **Folder 7 (Task 5 - gRPC Service-to-Service Communication)**: Verifies the gRPC server is active on port `8601` and `broker_grpc_calls_total` is exported.
- **Folder 8 (Task 6 - Durable Queues & Dead Letter Channel)**: Publishes an unsendable event to trigger the SQLite-backed Dead Letter Channel, fetches dead letters via `GET /dead-letters` (and filtered via `?topic=DeadLetterDemo&limit=5`), and tests `401`/`400` error gates. It then redelivers that dead letter (`POST /dead-letters/{id}/redeliver`: `202`, same `messageId`) and checks `404 dead_letter_not_found` for an unknown id.
- **Folder 9 (Task 7 - Prometheus & Grafana/Loki Observability)**: Scrapes `GET /metrics` for HTTP, dispatch, circuit breaker, HA reroute, in-flight load, thread pool, and durable message store gauges, and verifies structured JSON logs with correlation `requestId`s.
- **Folder 10 (Sagas)**: Creates an inventory with 10 chemicals and spawns 2 Infected Zombies through the services' queues. It runs a `cure-zombie` saga that completes (both steps `succeeded`, the cure requirement charged), and one the player can't pay for, which is compensated (`402 rejected_insufficient` on `pay`, the cure undone). It lists sagas by state and name, and checks `409 saga_not_failed` on retry, `400 invalid_saga` / `invalid_limit`, `404 saga_not_found`, `401` without a token, the `broker_sagas_total` metrics and the durable saga store in `/health`. Then it deletes its inventory. Needs the 5.0.0 broker, Zombie and Resource images.

The Base and Crafting collections use the broker the same way. Their setup credits the test player
through Resource Service's `POST /api/refund`, which the Gateway refuses, so it goes to the broker's
queue instead (`POST {{brokerUrl}}/queues/resource-service/api/refund`) with a service token minted
from `jwtSecret`. Both publish `ZoneUnlocked` on the broker and check that their service is among the
subscribers; the Base collection then claims the room the event opened. Base's barricades and facility
upgrades are service-only too (Game Service applies them): one request checks that the Gateway refuses
them, and the rest go to `{{brokerUrl}}/queues/base-service/...` with a Game Service token. Zone locks are
shared by every player, and the World collection or a passed exam may already have unlocked the Mathematics
Wing, so Base's locked-wing claim picks a room of a zone World Service reports locked when it runs (it is
skipped if every wing is unlocked). Their last request downloads
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

The Zombie and Resource collections' **Participant endpoints** folders call, directly, the endpoints that only the
coordinators use: the Gateway (Two-Phase Commit) and the Message Broker (sagas). The Gateway refuses these endpoints,
so the folders call them through the broker's queue (`{{brokerUrl}}/queues/{service}/...`) with a game-service token
minted from `jwtSecret` (a folder-level pre-request script). They need the **5.0.0** images. Each folder runs on its
own and can be run again: it spawns its zombies or creates its player, and uses ids made from a fresh `pRun`.

- **Zombie Service** (38 requests):
  - Two-Phase Commit `prepare` / `commit` / `abort` / `GET /api/tx/{txId}`: votes commit and abort (`zombie_busy`, `already_cured`, `not_a_tourist`), repeats (`already_prepared`, `already_committed`, `already_aborted`), `tx_mismatch`, `tx_committed`, `tx_aborted`, an abort remembered before its prepare (`aborted_before_prepare`), `tx_not_found` and `invalid_body`;
  - the saga steps `cure` / `record-loot` and their compensations `uncure` / `return-loot`: repeats (`already_cured_by_step`, `already_recorded`, `nothing_to_undo`), a step refused after its compensation and a compensation that arrives before its step (`step_cancelled`), `already_cured`, `not_a_tourist`, `zombie_not_found` and `invalid_body`;
  - `GET /status`.
- **Resource Service** (30 requests):
  - Two-Phase Commit holds: a held amount can't be spent (`402`), a prepare beyond the free balance votes abort with `missing`, commit deducts (`newBalance`), abort releases the hold and leaves the balance untouched, plus the same repeats and conflicts as Zombie;
  - the refund as a saga compensation (`compensates`): credited back once (`refunded`, then `already_refunded`), `nothing_to_refund` for a spend that never happened, which then cancels it (`409 spend_cancelled`), `refund_mismatch`, and `invalid_body`;
  - `GET /status`; the folder deletes its player at the end.

| Variable | Set by | Used for |
|---|---|---|
| `brokerUrl` | the collection (`http://localhost:8600`) | the broker's queues, for the routes the Gateway refuses |
| `jwtSecret` | the collection (the compose's `JWT_SECRET`) | minting the game-service token |
| `serviceJwt` | each folder's pre-request script | the bearer token of the broker calls |
| `pRun` | the first request of each Participant folder | unique transaction, step and idempotency ids for each run |
| `pInfectedA`, `pInfectedB`, `pTourist` | the Zombie folder's spawn requests | the zombies the checks act on |
| `pPlayer` | the Resource folder's first request | the player whose balance the checks hold, spend and refund |

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

The Base and Crafting collections cover lab 5 for Base and Crafting Service in four folders each (Base 8 to 11,
Crafting 6 to 9), and need their **5.0.0** images with the compose defaults (`Coordination__Mode=2pc`):

- **Cache:** reads the player's base (Base) or a recipe (Crafting) twice, `X-Cache: MISS` then `HIT` from the same
  node, changes it (a room claimed and unclaimed, the recipe updated), and checks that the next read is a `MISS`
  with the new value and the one after it a `HIT` (with `CACHE_DEBUG_HEADERS=true`);
- **Replication and failover:** one replica's `GET /status` and `GET /metrics` through the broker's queue, with
  `base-db-1..3` or `crafting-db-1..3` (exactly one primary, the others `standby`, or `down` while stopped);
- **Two-Phase Commit:** a committed transaction (a barricade; the Barricade Kit craft) with each participant's vote
  and acknowledgement, aborted ones (an infirmary without chemicals; the crafts for `pm_ghost_*`, which Player
  Service doesn't know, and for `pm_poor_*`, who has no materials), and `404 tx_not_found`;
- **Saga steps:** the Gateway refuses them (`404 route_not_found`); through the broker's queue, `400` without a
  step id, a compensation before its step (`nothing_to_revert`, `nothing_to_cancel`), an unknown action or craft
  (`404`), and a craft the Two-Phase Commit aborted (`409 craft_not_in_saga`).

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
