# Inventory — Deployment Guide

*Written 2026-08-14 on the `migrate_to_vertx_eb` branch. This is the exact method
for deploying the dev versions and the released versions of the stack. Companion
to [RUNBOOK.md](RUNBOOK.md) (day-2 operations: smoke, drills, backup, migrations)
and [VERTICLES.md](VERTICLES.md) (the architecture record).*

## What gets deployed

```
browser ──HTTP──▶ inventory-web-app (:8082, native)
                       │ HTTP
                       ▼
iOS app ──HTTP──▶ inventory-web-api (:8081, JVM)     ◀── the ONLY API entrypoint;
                       │                                  authenticates every request
                       │  BusEnvelope (request/reply, inventory.svc.*)
                       ▼
                  clustered Vert.x event bus  (internal network, fabric token)
                       │                                        │
                       ▼                                        ▼
              inventory-server (JVM)                inventory-exporter (:8083, JVM)
              worker verticles: CRUD,               consumes inventory.events.* facts
              audit, QR/label, users,               + polls audit_events.seq (always
              tokens, auth                          correct even with no bus)
                       │
                       ▼
                  postgres (:5432, volume pgdata)   ◀── Liquibase `migrate` runs first
```

- **All external inputs** (browser, mobile) enter through `inventory-web-api` and
  are authenticated there (bearer token, resolved by the auth worker over the
  bus). **Every envelope** names the acting user, asserts their roles, and
  presents the shared fabric token; workers refuse envelopes with a bad token
  (401) or a missing role (403) before doing any work.
- **Services on the bus are considered already authenticated** — membership in
  the cluster network is access. That is why the cluster network is
  `internal: true` and ports 7800/15701 are never published.
- The three bus members run as **JVM containers** (vertx-infinispan is the one
  component not proven under GraalVM native); the web-app stays native.

## Configuration (`.env` at the workspace root — compose and `just` auto-load it)

| Variable | Default | Notes |
|---|---|---|
| `POSTGRES_PASSWORD` | `inventory` | change outside dev |
| `INVENTORY_BUS_TOKEN` | `dev-bus-token` | the envelope fabric token; change outside dev, same value on gateway and server |
| `INVENTORY_ADMIN_EMAIL` / `INVENTORY_ADMIN_PASSWORD` | `admin@example.com` / `change-me` | seeded idempotently at server startup |
| `INVENTORY_PRINTER` / `INVENTORY_PRINTER_HOST` / `..._PORT` / `..._TAPE_MM` | `log` / – / `9100` / `24` | hardware label printer (Brother PT-P750W); consumed by inventory-server |
| `INVENTORY_VERSION` | `latest` | released deploys only (see below) |
| `INVENTORY_GHCR_OWNER` | `mykelalvis` | released deploys only |

## Deploying the dev versions

Three methods, fastest feedback first. All run from the workspace root.

### 1. Single-process dev (embedded workers) — inner loop

```sh
just dev-web-api          # gateway on :8081 with the worker set deployed in-process
just dev-webapp           # (second terminal) browser UI on :8082
```

The gateway's default `inventory.bus.workers=embedded` deploys the SAME worker
verticles inventory-server hosts, on the process-local bus, against in-memory
storage. Every request still crosses the envelope contract (token, roles,
attribution), so this is a faithful dev mirror of production minus the network.
Login: `admin@example.com` / `change-me`, or the seeded static bearer token
`dev-token`.

### 2. Two-process dev (real clustered fabric, no containers)

Terminal 1 — the worker host, clustered:

```sh
just _sync-libs
mvn -pl inventory-server quarkus:dev \
  -Dquarkus.http.port=8084 \
  -Dquarkus.vertx.cluster.clustered=true \
  -Dquarkus.vertx.cluster.host=127.0.0.1 -Dquarkus.vertx.cluster.port=15701 \
  -Djgroups.bind.address=127.0.0.1 \
  -Djgroups.tcpping.initial_hosts='127.0.0.1[7800],127.0.0.1[7801]'
```

Terminal 2 — the gateway in remote mode, joining the same cluster:

```sh
mvn -pl inventory-web-api quarkus:dev \
  -Dinventory.bus.workers=remote \
  -Dquarkus.vertx.cluster.clustered=true \
  -Dquarkus.vertx.cluster.host=127.0.0.1 -Dquarkus.vertx.cluster.port=15702 \
  -Djgroups.bind.address=127.0.0.1 -Djgroups.tcp.port=7801 \
  -Djgroups.tcpping.initial_hosts='127.0.0.1[7800],127.0.0.1[7801]'
```

Watch for `ISPN000094: Received new cluster view ... (2)` on both sides, then run
the smoke flow against :8081. This is the setup for debugging fabric behavior
(timeouts, refusals, serialization) without Docker.

### 3. Full dev stack (compose — the deployment rehearsal)

```sh
just build-all            # fast-jars (server, gateway, exporter) + native web-app + docker compose build
just up                   # postgres → migrate (Liquibase, exits 0) → server → gateway/exporter → web-app
just ps                   # everything Up; migrate Exited (0)
just smoke                # login → CRUD → QR → print-label → BFF view; ends SMOKE PASS
just down                 # stop, KEEP data       (just destroy = confirm-gated down -v)
```

This is the same `docker-compose.yml` a release runs — Postgres storage, the
internal cluster network with static member IPs (gateway 172.28.0.11, server
.12, exporter .13), and the fabric token from `.env`. Verification beyond smoke:

```sh
just logs inventory-server | grep ISPN000094    # cluster view should reach (3)
docker compose exec postgres psql -U inventory -d inventory \
  -c 'select action, principal from audit_events order by seq desc limit 5'
```

## Deploying the released versions

A release is a superproject tag; its deliverables are the four container images
in the **private** GHCR namespace `ghcr.io/<owner>/inventory-root/<module>:<version>`
(PLAN.md Phase 14 decision — mobile releases live on separate store tracks and
are not part of this stack). Until the Phase 14 `release.yml` automation is
built, images are produced and pushed manually; the deploy method on the target
host is identical either way.

### Producing a release (build host, manual until Phase 14 executes)

```sh
VERSION=0.1.0          # the release being cut
OWNER=mykelalvis

# 1. From the release tag, clean build + full verification
git checkout "v${VERSION}" && git submodule update --init
mvn -B verify

# 2. Build the artifacts and images
just build-all

# 3. Tag and push into the private inventory-root namespace
for m in inventory-server inventory-web-api inventory-exporter; do
  docker tag  ${m}:jvm  ghcr.io/${OWNER}/inventory-root/${m}:${VERSION}
  docker push ghcr.io/${OWNER}/inventory-root/${m}:${VERSION}
done
docker tag  inventory-web-app:native ghcr.io/${OWNER}/inventory-root/inventory-web-app:${VERSION}
docker push ghcr.io/${OWNER}/inventory-root/inventory-web-app:${VERSION}

# 4. Verify every package shows Private visibility in the GitHub UI (packages
#    inherit weird defaults; this gate is manual and mandatory).
```

### Deploying a release (target host)

Prerequisites: Docker + compose plugin; a GHCR token with `read:packages`;
the repo checkout **at the release tag** (it carries the compose files AND the
Liquibase changelogs the `migrate` service mounts):

```sh
git clone --recurse-submodules git@github.com:mykelalvis/inventory-root.git inventory
cd inventory && git checkout "v${VERSION}" && git submodule update --init inventory-impl

docker login ghcr.io          # user + read:packages token

cat > .env <<'EOF'            # real secrets, never the dev defaults
POSTGRES_PASSWORD=<strong>
INVENTORY_BUS_TOKEN=<strong-random>
INVENTORY_ADMIN_EMAIL=<you>
INVENTORY_ADMIN_PASSWORD=<strong>
INVENTORY_VERSION=<version>
EOF

docker compose -f docker-compose.yml -f docker-compose.release.yml pull
docker compose -f docker-compose.yml -f docker-compose.release.yml up -d
just smoke                    # or the curl flow in RUNBOOK.md
```

The overlay swaps every locally built image for its versioned GHCR image and
never builds; `migrate` still runs Liquibase to completion before the server
starts, so schema upgrades are part of every deploy.

### Upgrading and rolling back

```sh
# upgrade: bump the version, pull, re-up (data volume untouched)
sed -i '' 's/^INVENTORY_VERSION=.*/INVENTORY_VERSION=0.2.0/' .env
git checkout v0.2.0 && git submodule update --init inventory-impl
docker compose -f docker-compose.yml -f docker-compose.release.yml pull
docker compose -f docker-compose.yml -f docker-compose.release.yml up -d

# rollback: point INVENTORY_VERSION (and the checkout) back and re-up.
# CAVEAT: images roll back freely; the DATABASE only rolls back across
# releases whose changesets you also roll back (RUNBOOK.md "Migrations":
# `just rollback <count>`). Take a backup first: `just backup`.
```

## Security invariants (all deployments)

- The `cluster` network stays `internal: true`; **never** publish 7800 (JGroups)
  or 15701 (bus transport). Bus membership is access.
- `INVENTORY_BUS_TOKEN` is defense in depth inside the fabric, not the
  perimeter — rotate it by redeploying gateway and server together.
- Only :8081 (API), :8082 (web UI), and :8083 (exporter, optional) are ever
  published; inventory-server exposes nothing.
- The seeded admin credentials and the memory-mode `dev-token` are dev
  conveniences; released deploys must override them in `.env`.
