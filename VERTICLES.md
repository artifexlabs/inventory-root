# Verticles and the Event Bus

*Decision recorded 2026-08-14. This documents intent and a staged plan; no stage has
executed yet. Companion to [PLAN.md](PLAN.md) (whose Architecture/Topology bullets and
module table will need updating when the consolidation stage executes) and
[RUNBOOK.md](RUNBOOK.md).*

## The question

An arbitrary number of additional Quarkus/Vert.x services will integrate with the
inventory system, consuming inventory events — CRUD actions, exports, label printing,
and so on. Should the application split into independent verticles with events (and
possibly the existing request traffic) crossing the clustered Vert.x event bus?

## The decision

**One HTTP domain service + a bus that carries only facts.**

- **`inventory-web-api` becomes the single HTTP service**: REST surface, OpenAPI,
  OIDC exchange, the DAOs (`inventory-impl`), transactions, and the audit writes all
  live there. The `inventory-server` module is parked — not run as a process, not
  kept as a placeholder. (Everything is tagged `before-remove-inventory-server`.)
- **North-south request/response stays HTTP.** Browser → web-app → web-api and
  iOS → web-api are unchanged in kind.
- **The clustered Vert.x event bus carries after-commit domain events only** —
  announcements of what already happened, payload-identical to the audit trail.
- **The `audit_events` table is the durable log of record.** It is already written in
  the same Postgres transaction as every mutation, which makes it a transactional
  outbox we get for free. Consumers replay/catch-up from it; the bus is a latency
  optimization, never a correctness dependency.
- **No hub service, no broker.** The Vert.x bus is peer-to-peer. If consumer needs
  ever exceed what a Postgres cursor sustains (or cross-datacenter fan-out appears),
  the escape hatch is a real broker (Kafka/NATS) — a deliberate future decision, not
  this one.

The minimum viable consumer is therefore: a Quarkus service with a Postgres
connection, polling a cursor. Joining the bus upgrades it from poll-interval latency
to sub-second push. That is what makes "arbitrary number of services" cheap.

## Why not the alternatives

**Bus request-reply for web-app → web-api (→ domain) traffic.** Those hops carry HTTP
semantics the bus cannot: status codes the UI branches on, content types
(`image/png` QRs, raw label bytes), and streamed asset upload/download (bus messages
are fully buffered in memory). The iOS app can never join a Vert.x cluster, so the
HTTP surface must exist anyway; OIDC and sessions are HTTP-shaped; and cluster
membership would become an availability dependency for every page load. Request-reply
over the bus is just RPC on a worse transport for this shape of traffic.

**`inventory-server` as an event "clearing house."** The clustered bus has no center:
members connect peer-to-peer and messages flow producer→consumer directly. A hub JVM
would add a hop and a single point of failure while re-implementing, badly, what the
transport already does (or what a broker would do properly).

**Commands over the bus** (mutations entering the system as events). Callers need the
synchronous answer — the created item, its ID, or the constraint violation. The bus
is at-most-once, so a dropped message is a silently lost write. And the repo's core
invariant — the audit row commits in the same transaction as the change — dies when
the change happens in a consumer detached from the request. Events are **facts, not
commands**: the mutation happens synchronously over HTTP; the fact is published after
commit.

**A token-generation service to gate bus access.** The bus has no checkpoint where a
token could be enforced — membership *is* access: any cluster member can publish to
and subscribe on any address. Envelope-token validation in consumers protects only
against spoofed content, not eavesdropping or address squatting. Real bus admission
control is at the cluster-membership/transport layer (below). Service-account tokens
for semi-trusted integrations already exist: `TokenService`/`api_tokens` over HTTPS,
with issue/revoke/list and admin UI. A mostly-empty service holding a lock with no
door is cost without function.

| Option | Verdict |
|---|---|
| Status quo (HTTP only, no events) | Every new consumer is bespoke polling/scraping; no push; rejected as the N-consumer story |
| **One HTTP tier + bus facts + audit replay (chosen)** | Durable log already exists in-tx; consumers correct even while down; bus optional per consumer; no new stateful infra |
| Bus everywhere, incl. request-reply | Loses HTTP semantics/streaming; iOS excluded; cluster gates page loads; big rewrite solving no current problem |
| Broker (Kafka/NATS) | Real replay/consumer groups, but new stateful infra duplicating what `audit_events` provides at this scale; revisit on outgrowth |

## Event contract

Package `org.lawfulevil.inventory.api.events` (new, in `inventory-api`):

- **Payload**: the serialized `AuditEvent`, plus a version field —
  `{v: 1, id, ts, principal, action, targetId, details?}`. Additive changes only;
  a breaking change bumps `v` and publishes both shapes for a deprecation window.
  `JsonObject` crosses the clustered bus natively; no custom codecs.
- **Addresses**: `publish` (fan-out; never `send`) to `inventory.events` and to
  `inventory.events.<category>`, category = the action prefix
  (`item`, `location`, `asset`, `region`, `user`, `token`, `label`). The action
  vocabulary is the existing audit vocabulary: `item.create/update/delete/contain/
  uncontain/move`, `location.create/delete`, `asset.attach/delete`,
  `region.create/delete`, `user.create/delete/set-admin/identity-link`,
  `token.revoke`, `label.print`.
- **`EventPublisher`**: `void publish(AuditEvent e)` — fire-and-forget, never throws,
  never blocks; ships with `EventPublisher.NOOP`. Mutation success must never couple
  to publication.
- **Consumer contract**: handlers are idempotent and dedupe by event `id`. The
  `principal` field is provenance — a record of who acted — never a credential a
  consumer re-authorizes with (authorization already happened at the HTTP tier).

## Emission semantics: publish after commit

Events publish at the same choke points that build audit rows — the private
`audit(conn, …)` helpers in `PgInventorySystem` / `PgLocationSystem` / `PgAssetStore`
/ `PgRegionSystem` and the auto-commit `PgAudit.record` path — but **after** the
transaction (or statement) completes successfully. Publishing inside the transaction
is rejected: it announces changes that may roll back. This is a dual-write and it is
accepted: if the process dies between commit and publish, the row exists, the bus
message is lost, and reconciliation (below) covers it. Exactly-once emission would
need a relay/CDC daemon that the catch-up protocol makes unnecessary.

## Consumer catch-up protocol

1. `audit_events` gains `seq BIGSERIAL` (indexed; changeset `013-audit-seq.yaml`).
   ULIDs are assigned before commit, so ULID order can disagree with commit order
   under concurrency; `seq` is the reliable cursor, read with a small overlap.
2. `AuditReader` gains `since(long seq, int limit)`.
3. Consumer loop: page `since(cursor)` until drained → subscribe to
   `inventory.events.*` → dedupe by `id` → advance the durable cursor (consumer's own
   table). A periodic reconciliation pass re-reads from `cursor − overlap` to sweep
   anything the bus dropped.
4. **Poll-only mode is fully correct** with zero cluster configuration — the same
   loop with a shorter interval and no subscription.

## Security model

- The cluster network is private (compose network / k8s network policy); the bus is
  never exposed. Cluster manager member authentication + encryption (JGroups
  auth/TLS under vertx-infinispan) gate membership. **Membership is trust**: only
  fully-trusted internal services join.
- Semi-trusted integrations never join the cluster. They speak HTTPS to web-api with
  existing bearer tokens (issue/revoke via `TokenService`, managed in the admin UI).
  Trust level picks the surface.
- Bus payloads are data. They already flow to the audit UI, so they carry no secrets;
  keep it that way.

## Staged plan (each stage gated; everything off by default)

1. **Contract + no-op wiring** — **EXECUTED 2026-08-14.** `events` package in
   `inventory-api` (`EventPublisher` with `NOOP` + `announce`/`announceAll`,
   `InventoryEvents` addresses + versioned wire format); the published fact IS the
   audit event (same id, built before the insert so row and bus payload match);
   `Pg*` systems announce after commit, `PublishingAuditSink` decorates the sink
   paths. *Gate met: full verify green, zero behavior change.*
2. **Cursorable log** — **EXECUTED 2026-08-14.** Changeset `013-audit-seq.yaml`
   (identity column, NOT bigserial — Liquibase degrades serial types on addColumn);
   `AuditReader.since(seq, limit)` returning `SequencedEvent` in both impls. *Gate
   met: concurrent-writer paging test — strictly increasing seq, exactly once.*
3. **Local bus** — **EXECUTED 2026-08-14.** `quarkus-vertx`;
   `inventory.events.bus=none|local|clustered` (default `none`). *Gate met:
   LocalBusPublishTest (event on both addresses ⇒ same-id row already committed);
   native container build of the consolidated web-api succeeds.*
4. **HTTP consolidation** — **EXECUTED 2026-08-14.** REST resources,
   `InventoryBackendProducer`, `BearerTokenFilter`/`CurrentUser`, and OpenAPI moved
   from `inventory-server` into `inventory-web-api` (package
   `org.lawfulevil.inventory.webapi`); the `ApiProxyResource` pass-through and its
   HTTP stub died (nothing left to proxy); `ItemViewsResource` now composes its
   aggregates from the domain beans in-process instead of HTTP self-calls; webapp
   config unchanged (`inventory.web-api.url`); compose runs web-api with the pg +
   printer env on :8081; `inventory-server` is parked (out of the reactor and
   compose; repo + history remain, tagged `before-remove-inventory-server`).
   *Gate: 49 web-api tests green (all migrated domain tests incl. Pg/Testcontainers
   + rewritten views tests) and the full-workspace verify + dev-mode smoke below.*
5. **Reference consumer: `inventory-exporter`** — **EXECUTED 2026-08-14.** New
   module/repo (:8083): `ExportLoop` drains `audit_events.seq` from a durable
   cursor; `item.*`/`label.print` land in `exports` exactly once (event-id PK);
   cursor advances in the same transaction as its batch; the bus only nudges the
   drain — data always comes from the table. In base compose it runs poll-only
   (fully correct, no cluster). *Gate met: kill-and-restart drill test.*
6. **Clustered bus in compose** — **EXECUTED 2026-08-14.** Opt-in overlay
   `docker-compose.cluster.yml`: vertx-infinispan (pinned to the Infinispan 14
   jakarta line; 15 hides an API vertx needs, 13 is javax), JGroups TCPPING on an
   internal-only network with fully static addressing — the services sit on two
   networks, so interface guessing and DNS can disagree; static cluster-net IPs pin
   membership (:7800), discovery, AND the event-bus message transport
   (`quarkus.vertx.cluster.host`/`:15701` — a separate socket whose localhost
   default silently drops every remote delivery). Bus members run as JVM containers
   (the documented native fallback). *Gate met: 2-node view forms; create→export in
   329 ms against a 30 s poll interval; exporter killed mid-stream missed nothing
   (recovered at the first tick, exactly once).*
7. **CI + runbook** — **EXECUTED 2026-08-14** (CI gate lands with the next push).
   `ClusteredBusTest` — two clustered Vert.x nodes over loopback, same stack as the
   overlay — runs inside plain `mvn verify`, so CI exercises the clustered fabric
   on every build. RUNBOOK gains the events/cluster section: ports, split-brain
   symptoms, "a consumer is just a cursor" recovery. NOTE for the eventual push:
   `inventory-exporter` must be added to the `SUBMODULE_TOKEN` fine-grained PAT's
   repository list or CI checkout will fail.

## Risks and open unknowns

- **Cluster manager under GraalVM native** is unproven here — gated at stages 3/6,
  JVM-container fallback documented above.
- **Dual-write window** (commit-then-publish): mitigated by reconciliation; accepted.
- **The audit vocabulary becomes a public contract.** Action names and `details`
  shapes need the `v`-field discipline once a consumer exists.
- **Idempotency is a contract, not a mechanism** — stated in the events package
  javadoc, enforced in the exporter's tests.
- **Memory mode never supports cross-process consumers** (per-JVM state, no durable
  log) — pg mode only, matching the existing constraint.
- **Consolidation ripples**: PLAN.md's topology/module-responsibility text, RUNBOOK,
  compose, devcontainer, and CI all reference `inventory-server`; stage 4 carries a
  documentation sweep.
