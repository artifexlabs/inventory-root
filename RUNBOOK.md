# Inventory — Deploy & Day-2 Runbook

*Phase 7 deliverable (2026-08-07). Everything here runs from the workspace root on a
machine with Docker; macOS included (native builds happen inside Linux builder
containers).*

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

## Hardware label-printer smoke (deferred)

Blocked on the printer-vendor unknown. When a printer exists: point the (future)
transport at it, run the smoke flow's `print-label` step, and confirm a physical
label with a scannable QR that deep-links to `/i/{id}`.

## Notes

- Clustered Vert.x event bus: NOT configured — no inter-service event-bus traffic
  exists yet (services talk HTTP). Add clustering config only when a consumer appears.
- Orchestrator target (swarm/nomad/k8s) still open; this compose file is the portable
  reference deployment.
