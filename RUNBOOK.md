# Inventory — Deploy & Day-2 Runbook

*Phase 7 deliverable (2026-08-07). Everything here runs from the workspace root on a
machine with Docker; macOS included (native builds happen inside Linux builder
containers).*

## Task runner: the Justfile is the executor of record

*Since 2026-08-09 every task below is executed via the [Justfile](Justfile) so the
procedures stay verified instead of drifting as prose. The shell detail in each
section remains as the narrative of what the recipe does — but run the recipe.*
`just` (no arguments) lists all tasks; requires **just ≥ 1.58** (installed locally
and in the devcontainer). Recipes that merely delegate to Maven say so in their
output.

| Runbook section | Recipe(s) |
|---|---|
| Build native images | `just native <module>` · `just natives` · `just images` · `just build-all` |
| JVM build + tests | `just verify` *(delegates to `mvn -B verify`)* |
| Bring up / tear down | `just up` · `just ps` · `just logs [service]` · `just down` · `just destroy` *(confirm-gated)* |
| Smoke flow | `just smoke` *(asserts each step, ends `SMOKE PASS`)* |
| Restart drills | `just drill-warm` · `just drill-cold` · `just drill-empty` *(confirm-gated)* |
| Backup / restore | `just backup [file]` *(dated filename by default)* · `just restore <file>` *(confirm-gated)* |
| Migrations | `just migrate` · `just rollback [count]` *(confirm-gated)* |
| Hardware printer smoke | `just print-label <item-id>` after configuring the printer env |
| Hardware-FREE printer smoke (end-to-end raster bytes) | `just smoke-fake-printer` |
| Mobile app builds | `just mobile-build` *(= ios-build + android-build)* · `just ios-build` · `just ios-test` · `just ios-regen` · `just android-build` *(no-op until scaffolded)* |

Configuration comes from the environment (or `.env`, which just auto-loads):
`INVENTORY_SERVER_URL`, `INVENTORY_WEB_API_URL`, `INVENTORY_ADMIN_EMAIL`,
`INVENTORY_ADMIN_PASSWORD`, `POSTGRES_PASSWORD` — defaults match the compose stack.

## Build native images

```sh
mvn -pl inventory-web-api -am package -DskipTests -Dnative -Dquarkus.native.container-build=true
mvn -pl inventory-web-app -am package -DskipTests -Dnative -Dquarkus.native.container-build=true
docker compose build
```

The `native` Maven profile lives in `inventory-parent`; `-Dnative` activates it.
The server image installs `fontconfig` + `dejavu-sans-fonts` — required for label text
rendering (quarkus-awt). Native images are Linux-only by design; macOS runs them via
the compose stack below, never directly.

## Bring up / tear down

```sh
docker compose up -d      # postgres -> liquibase migrate (runs, exits 0) -> the three apps
docker compose ps         # all Up; migrate shows Exited (0)
docker compose down       # stop stack, KEEP data
docker compose down -v    # stop stack, DESTROY database volume
```

Ports: server 8080, web-api 8081, webapp 8082. Browser entry: http://localhost:8082
(login with the seeded admin, default `admin@example.com` / `change-me` — override via
`INVENTORY_ADMIN_EMAIL` / `INVENTORY_ADMIN_PASSWORD`).

## Smoke flow (the standing check)

```sh
TOKEN=$(curl -s -X POST localhost:8080/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@example.com","password":"change-me"}' | sed -E 's/.*"token":"([^"]+)".*/\1/')
curl -s -H "Authorization: Bearer $TOKEN" localhost:8080/api/v1/items            # CRUD read
ID=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"smoke-item","type":"tool"}' localhost:8080/api/v1/items | sed -E 's/.*"id":"([^"]+)".*/\1/')
curl -s -H "Authorization: Bearer $TOKEN" localhost:8080/api/v1/items/$ID/qr.png -o /tmp/qr.png
file /tmp/qr.png                                                                 # PNG image data
curl -s -X POST -H "Authorization: Bearer $TOKEN" localhost:8080/api/v1/items/$ID/print-label -w '%{http_code}\n'
curl -s -H "Authorization: Bearer $TOKEN" "localhost:8081/api/v1/views/items?query=smoke" # BFF view
```

QR gate: decode `/tmp/qr.png` with zxing and confirm it encodes
`$INVENTORY_QR_BASE_URL/i/$ID` (the JVM-side `QrAndLabelTest` checks the same
round-trip on every build).

## Restart drills

- **Warm** (process bounce, data intact):
  `docker compose restart inventory-web-api` → smoke flow passes; previously created
  items still present.
- **Cold** (full stack down, volume kept):
  `docker compose down && docker compose up -d` → migrate re-runs idempotently
  (no-op), data intact.
- **From empty**: `docker compose down -v && docker compose up -d` → Liquibase builds
  the schema from nothing; seeded admin can log in.

## Backup / restore

```sh
# Backup (while running)
docker compose exec postgres pg_dump -U inventory -Fc inventory > inventory-$(date +%F).dump
# Restore (into a fresh volume)
docker compose down -v && docker compose up -d postgres
docker compose exec -T postgres pg_restore -U inventory -d inventory --clean --if-exists < inventory-YYYY-MM-DD.dump
docker compose up -d
```

## Migrations (day-2)

Forward: add a changeset (with rollback) under
`inventory-impl/src/main/resources/db/changeset/`, include it in
`db/changelog-master.yaml`, then `docker compose run --rm migrate` (or just
`up -d` — migrate always runs before the server).

Backward:
```sh
docker compose run --rm migrate --url=jdbc:postgresql://postgres:5432/inventory \
  --username=inventory --password=$POSTGRES_PASSWORD \
  --search-path=/liquibase/changelog --changelog-file=db/changelog-master.yaml \
  rollback-count 1
```

## Hardware label-printer smoke (Brother PT-P750W)

Vendor resolved 2026-08-08: Brother PT-P750W (Wi-Fi, raw TCP 9100, Brother raster
protocol; TZe tape ≤ 24 mm at 180 dpi). **Steps 1–3 PASSED 2026-08-09**: printer on
the LAN at 10.0.1.130 (in the workspace `.env` — update there if DHCP moves it),
`just print-label` printed a physical 414-line label and returned 204 with the
`label.print` audit row. The compose stack forwards `INVENTORY_PRINTER*` from `.env`
to the server (defaults keep the `log` printer).

1. Put the P750W on the LAN (its print server listens on TCP 9100); note its IP.
2. Configure the server: `INVENTORY_PRINTER=brother-p750w`,
   `INVENTORY_PRINTER_HOST=<printer-ip>` (port defaults to 9100, tape to 24 mm) —
   both live in the workspace `.env`.
3. Run the smoke flow's `print-label` step against a real item.
4. Gate (PASSED 2026-08-09): both smoke labels scanned reliably on an iPhone 15 Pro —
   the ~18 mm QR from 24 mm tape needs no module-size/quiet-zone iteration.

No hardware handy? `just smoke-fake-printer` proves the identical path end to end:
it brings the stack up with the `fake-printer` compose service (an alpine `nc`
TCP-9100 sink, profile-gated) as the printer target, POSTs print-label through the
NATIVE server, and verifies the captured job's raster bytes (100-byte invalidate +
ESC@ … 0x1A). Verified green 2026-08-09 on the rebuilt native image; a plain
`just up` never starts the sink and honors `.env`'s real `INVENTORY_PRINTER_HOST`.

## Web islands (Phase 8 — inventory-web-app/src/main/web)

The item page's photo annotator (`<space-annotator>`) is a **Svelte custom
element** built by Vite inside the Maven build: `frontend-maven-plugin` downloads
its own Node (v20.18.1 — the HOST needs no Node), runs `npm install` + `vite
build` at generate-resources, and `vitest` in the test phase. The bundle ships in
the jar as `/islands/space-annotator.js`; `mvn verify` (and therefore
`just verify`) remains the one command.

- Sources: `inventory-web-app/src/main/web/` (`src/SpaceAnnotator.svelte`,
  pure geometry in `src/annotator-core.ts`, vitest in `test/`).
- Iterating: `cd inventory-web-app/src/main/web && PATH="$PWD/../../../target/node:$PATH" npm run dev`
  (rebuild-on-change into target/classes; pair with `quarkus dev`).
- Observing the full flow live: `just dev-web-api` and
  `just dev-webapp` in two terminals, then http://localhost:8082
  (admin@example.com / change-me by default).
- Adding an island: new `.svelte` + entry import, or a second Vite entry; mount it
  from a Qute template with a `<script type="module">` tag.

## iOS app build (Phase 12 — inventory-mobile-apps/inventory-ios-app)

The mobile app is **not a Maven module**: it is a native Swift/SwiftUI universal
(iPhone + iPad) Xcode project, built by `xcodebuild` through the Justfile — macOS
only, never part of `mvn verify`, the compose stack, or the Linux CI lanes.

```sh
just mobile-build # ALL mobile apps: ios-build then android-build
just ios-build    # Debug build for the iOS Simulator, unsigned (CODE_SIGNING_ALLOWED=NO)
just ios-test     # xcodebuild test on a simulator (INVENTORY_IOS_SIMULATOR, default "iPhone 16")
just ios-regen    # regenerate InventoryApp.xcodeproj from project.yml (XcodeGen)
just ios-open     # open the project in Xcode
just android-build# Gradle build once the Android app is scaffolded; loud no-op today
```

The skeletal iOS app (2026-08-09) is generated by **XcodeGen** — `project.yml` is the
source of truth, the `.xcodeproj` (with its shared scheme) is committed so plain
Xcode/xcodebuild need nothing extra. Sources typecheck against the macOS SDK on a
CLT-only machine; the full compile gate is `just ios-build` wherever Xcode exists.

Configuration: `INVENTORY_IOS_SCHEME` (default `InventoryApp`),
`INVENTORY_IOS_SIMULATOR`. The recipes preflight their environment and fail with an
actionable message when full Xcode is absent (Command Line Tools alone are not
enough — see [MOBILE-READINESS.md](MOBILE-READINESS.md)) or when the app scaffold
does not exist yet (Phase 12 not executed). Signed device builds, TestFlight, and
macOS CI runners are deliberately outside these recipes until distribution starts.

## Domain events and the clustered bus (VERTICLES.md)

Every mutation writes an `audit_events` row in its own transaction; that table is
the durable event log. `inventory-exporter` (:8083) is the reference consumer: it
pages `audit_events.seq` from a durable cursor and lands `item.*` / `label.print`
facts in its `exports` table exactly once. **Poll-only mode is fully correct** —
the base compose runs it that way with no cluster at all.

The clustered bus is an opt-in latency upgrade:

```sh
mvn -pl inventory-web-api,inventory-exporter -am package -DskipTests   # fast-jars
docker compose -f docker-compose.yml -f docker-compose.cluster.yml up -d
```

- web-api and the exporter join a Vert.x cluster (vertx-infinispan, JGroups
  TCPPING static discovery) over the internal-only `cluster` network; facts
  arrive sub-second instead of at the poll interval. Both run as JVM containers
  there — the cluster manager is the one piece not proven under GraalVM native
  (documented fallback); everything else stays native.
- **Ports**: JGroups TCP 7800 (+`FD_SOCK2` at 57800) — cluster network only,
  NEVER published. Bus membership is access; the network is the security boundary.
- **Symptoms**: `ISPN000094: Received new cluster view ... (2)` on both sides =
  healthy pair. Repeated view churn or `(1)` views on both = split brain — check
  `jgroups.tcpping.initial_hosts` matches the service names and that both
  containers share the `cluster` network. Events during a partition are NOT lost:
  the exporter's reconciliation poll sweeps them from the table.
- **Consumer recovery is trivial by design**: a consumer is just a cursor. Wipe or
  reset its `consumer_cursors` row and it replays idempotently from wherever you
  point it (`seq = 0` = full history).
- Config: `inventory.events.bus` = `none` (default) | `local` | `clustered`;
  exporter poll interval `inventory.exporter.poll-interval-ms` (30 s under the
  overlay, so live latency demonstrably comes from the bus).

## Notes

- Orchestrator target (swarm/nomad/k8s) still open; this compose file is the portable
  reference deployment.
