# Inventory workspace task runner. RUNBOOK.md is the narrative; this file is
# the executor of record — run tasks from here so they stay verified.
# `just` with no arguments lists every task.

# --- toolchain gate ----------------------------------------------------------
# Requires just >= 1.58 (what the workspace and devcontainer install). Future
# upgrades are fine; raise this floor when a newer feature is adopted.

_version_gate := if semver_matches(just_version(), ">=1.58.0") == "true" { "ok" } else { error("this Justfile requires just >= 1.58.0, found " + just_version()) }

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

# --- configuration (override via environment or .env) ------------------------

server_url := env('INVENTORY_SERVER_URL', 'http://localhost:8080')
webapi_url := env('INVENTORY_WEB_API_URL', 'http://localhost:8081')
webapp_url := env('INVENTORY_WEBAPP_URL', 'http://localhost:8082')
admin_email := env('INVENTORY_ADMIN_EMAIL', 'admin@example.com')
admin_password := env('INVENTORY_ADMIN_PASSWORD', 'change-me')
pg_password := env('POSTGRES_PASSWORD', 'inventory')

native_flags := "-DskipTests -Dnative -Dquarkus.native.container-build=true"

# List every task.
default:
    @just --list --unsorted

# --- build -------------------------------------------------------------------

# Build + JVM-test every module (delegates to Maven).
[group('build')]
verify:
    @echo "-> delegating to Maven: mvn -B verify (all six modules, JVM tests)"
    mvn -B verify

# Native executable for one module, compiled in the Linux builder container.
[group('build')]
native module:
    @echo "-> delegating to Maven: native build of {{ module }} ({{ native_flags }})"
    mvn -pl {{ module }} -am package {{ native_flags }}

# Native executables for all three apps.
[group('build')]
natives: (native "inventory-server") (native "inventory-web-api") (native "inventory-webapp")

# Container images from the native executables.
[group('build')]
images:
    docker compose build

# Everything: natives, then images.
[group('build')]
build-all: natives images

# --- stack -------------------------------------------------------------------

# Start the stack: postgres -> liquibase migrate (exits 0) -> the three apps.
[group('stack')]
up:
    docker compose up -d
    @just ps

# Service status (migrate correctly shows Exited (0)).
[group('stack')]
ps:
    docker compose ps -a --format 'table {{{{.Service}}\t{{{{.State}}\t{{{{.Status}}'

# Follow logs; `just logs inventory-server` for one service.
[group('stack')]
logs service="":
    docker compose logs -f {{ service }}

# Stop the stack, KEEP the database volume.
[group('stack')]
down:
    docker compose down

# Stop the stack and DESTROY the database volume.
[group('stack')]
[confirm("This DESTROYS the database volume. Continue? (y/N)")]
destroy:
    docker compose down -v

# --- smoke (the standing check) ----------------------------------------------

# Login -> CRUD -> qr.png is a real PNG -> print-label 204 -> BFF view.
[group('smoke')]
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "-> smoke against {{ server_url }} (server) and {{ webapi_url }} (web-api)"
    TOKEN=$(curl -s -X POST {{ server_url }}/api/v1/auth/login \
      -H 'Content-Type: application/json' \
      -d '{"email":"{{ admin_email }}","password":"{{ admin_password }}"}' \
      | sed -E 's/.*"token":"([^"]+)".*/\1/')
    [ -n "$TOKEN" ] && [ ${#TOKEN} -eq 26 ] || { echo "FAIL: login did not yield a token"; exit 1; }
    echo "ok: login (token acquired)"
    curl -sf -H "Authorization: Bearer $TOKEN" {{ server_url }}/api/v1/items > /dev/null
    echo "ok: items list"
    ID=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"name":"smoke-item","type":"tool"}' {{ server_url }}/api/v1/items \
      | sed -E 's/.*"id":"([^"]+)".*/\1/')
    echo "ok: created item $ID"
    curl -sf -H "Authorization: Bearer $TOKEN" {{ server_url }}/api/v1/items/$ID/qr.png -o /tmp/inventory-smoke-qr.png
    file /tmp/inventory-smoke-qr.png | grep -q 'PNG image data' || { echo "FAIL: qr.png is not a PNG"; exit 1; }
    echo "ok: qr.png is a real PNG (/tmp/inventory-smoke-qr.png; decode gate: it must encode <qr-base-url>/i/$ID)"
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" {{ server_url }}/api/v1/items/$ID/print-label)
    [ "$CODE" = "204" ] || { echo "FAIL: print-label returned $CODE"; exit 1; }
    echo "ok: print-label 204 (LabelPrinter dispatched + audited)"
    curl -sf -H "Authorization: Bearer $TOKEN" "{{ webapi_url }}/api/v1/views/items?query=smoke" | grep -q smoke-item \
      || { echo "FAIL: BFF view missing smoke-item"; exit 1; }
    echo "ok: BFF view answers through web-api"
    echo "SMOKE PASS"

# POST print-label for an existing item id (hardware gate: scan the physical label).
[group('smoke')]
print-label id:
    #!/usr/bin/env bash
    set -euo pipefail
    TOKEN=$(curl -s -X POST {{ server_url }}/api/v1/auth/login \
      -H 'Content-Type: application/json' \
      -d '{"email":"{{ admin_email }}","password":"{{ admin_password }}"}' \
      | sed -E 's/.*"token":"([^"]+)".*/\1/')
    curl -s -o /dev/null -w 'print-label -> %{http_code}\n' -X POST \
      -H "Authorization: Bearer $TOKEN" {{ server_url }}/api/v1/items/{{ id }}/print-label
    echo "reminder: hardware printing needs INVENTORY_PRINTER=brother-p750w and INVENTORY_PRINTER_HOST on the server"

# --- restart drills ----------------------------------------------------------

# Warm: bounce the server process; data must survive.
[group('drill')]
drill-warm:
    docker compose restart inventory-server
    @just _wait-ready
    @just smoke

# Cold: full stack down and up, volume kept; migrate re-runs idempotently.
[group('drill')]
drill-cold:
    docker compose down
    docker compose up -d
    @just _wait-ready
    @just smoke

# From empty: destroy the volume, rebuild schema from nothing.
[group('drill')]
[confirm("This DESTROYS the database volume before the drill. Continue? (y/N)")]
drill-empty:
    docker compose down -v
    docker compose up -d
    @just _wait-ready
    @just smoke

_wait-ready:
    #!/usr/bin/env bash
    set -euo pipefail
    echo -n "waiting for {{ server_url }} "
    for i in $(seq 1 60); do
      CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST {{ server_url }}/api/v1/auth/login \
        -H 'Content-Type: application/json' \
        -d '{"email":"{{ admin_email }}","password":"{{ admin_password }}"}' || true)
      [ "$CODE" = "200" ] && { echo " ready"; exit 0; }
      echo -n "."; sleep 1
    done
    echo " FAIL: server not ready after 60s"; exit 1

# --- backup / restore / migrations (day-2) -----------------------------------

# pg_dump the running database (custom format).
[group('day2')]
backup file=("inventory-" + datetime("%F") + ".dump"):
    docker compose exec postgres pg_dump -U inventory -Fc inventory > {{ file }}
    @echo "backup written: {{ file }}"

# Restore a dump into a FRESH volume, then start the stack.
[group('day2')]
[confirm("This DESTROYS the current database volume before restoring. Continue? (y/N)")]
restore file:
    docker compose down -v
    docker compose up -d postgres
    sleep 5
    docker compose exec -T postgres pg_restore -U inventory -d inventory --clean --if-exists < {{ file }}
    docker compose up -d
    @just ps

# Apply pending Liquibase changesets (idempotent; also runs on every `just up`).
[group('day2')]
migrate:
    docker compose run --rm migrate

# Roll back the last N changesets.
[group('day2')]
[confirm("Rolling back applied changesets. Continue? (y/N)")]
rollback count="1":
    docker compose run --rm migrate \
      --url=jdbc:postgresql://postgres:5432/inventory \
      --username=inventory --password={{ pg_password }} \
      --search-path=/liquibase/changelog --changelog-file=db/changelog-master.yaml \
      rollback-count {{ count }}
