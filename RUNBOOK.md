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

Configuration comes from the environment (or `.env`, which just auto-loads):
`INVENTORY_SERVER_URL`, `INVENTORY_WEB_API_URL`, `INVENTORY_ADMIN_EMAIL`,
`INVENTORY_ADMIN_PASSWORD`, `POSTGRES_PASSWORD` — defaults match the compose stack.

## Build native images

```sh
mvn -pl inventory-server  -am package -DskipTests -Dnative -Dquarkus.native.container-build=true
mvn -pl inventory-web-api -am package -DskipTests -Dnative -Dquarkus.native.container-build=true
mvn -pl inventory-webapp  -am package -DskipTests -Dnative -Dquarkus.native.container-build=true
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
  `docker compose restart inventory-server` → smoke flow passes; previously created
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
protocol; TZe tape ≤ 24 mm at 180 dpi). Once the Phase 9 pipeline lands:

1. Put the P750W on the LAN (its print server listens on TCP 9100); note its IP.
2. Configure the server: `INVENTORY_PRINTER=brother-p750w`,
   `INVENTORY_PRINTER_HOST=<printer-ip>` (port defaults to 9100, tape to 24 mm).
3. Run the smoke flow's `print-label` step against a real item.
4. Gate: the printed label's QR phone-scans and resolves through `/i/{id}` to the
   item page. If an ~18 mm QR won't scan reliably, iterate module size / quiet zone
   in the composer before anything else.

## Notes

- Clustered Vert.x event bus: NOT configured — no inter-service event-bus traffic
  exists yet (services talk HTTP). Add clustering config only when a consumer appears.
- Orchestrator target (swarm/nomad/k8s) still open; this compose file is the portable
  reference deployment.
