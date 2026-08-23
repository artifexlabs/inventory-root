# Verticles and the Event Bus

*Decision recorded 2026-08-14; all seven stages EXECUTED the same day, then REVISED
the same day by the `migrate_to_vertx_eb` work (see "The decision" below — the bus
gained a second plane and `inventory-server` came back as its worker host), then
EXTENDED 2026-08-21/22 by Phase 21 (PLAN.md): the bus gained a status plane, a
printer packet protocol, and single-door storage isolation, and again 2026-08-22 by
Phase 22 (an originating request id on every envelope, and the `data.*` manifest
vocabulary). This document describes the architecture as built. Companion to [PLAN.md](PLAN.md),
[deploy/DEPLOYMENT.md](deploy/DEPLOYMENT.md) (how to run it), and
[RUNBOOK.md](RUNBOOK.md).*

## The question

An arbitrary number of additional Quarkus/Vert.x services will integrate with the
inventory system, consuming inventory events — CRUD actions, exports, label printing,
and so on. Should the application split into independent verticles with events (and
possibly the existing request traffic) crossing the clustered Vert.x event bus?

## The decision

**One authenticated HTTP gateway + a bus with two planes** *(grown to five kinds
of traffic by Phase 21 — see the traffic list below)*.

*(Revised 2026-08-14. The original decision was "one HTTP domain service + a bus that
carries only facts," with `inventory-server` parked. The owner then directed that ALL
domain work cross the bus; the fact plane, the audit log, and the catch-up protocol
survived that revision untouched — only the topology and the request path changed.)*

- **`inventory-web-api` is the authenticated HTTP gateway**: REST surface, OpenAPI,
  the OIDC exchange, and — decisively — the authentication boundary. Every external
  input (browser, iOS) is authenticated here and nowhere else. It owns no domain
  state in deployment.
- **`inventory-server` is the bus worker host**: every worker verticle deploys
  here. *(Revised again by Phase 21, 2026-08-21:)* the workers no longer hold the
  DAOs themselves — `StorageVerticle` is the SINGLE holder of every backend (the
  Pg/memory implementations from the `inventory-impl-root` train), serving
  whole-unit domain operations at the internal `storage` address. The public
  verticles are admission + routing (most simply `forward(...)` to storage),
  Labels and Catalog orchestrate, and label composition/rasterizing happens in
  `LabelPrinterVerticle` behind the `printer.*` addresses. (inventory-server was
  parked by stage 4 and restored by the revision; the parking tag
  `before-remove-inventory-server` still marks that moment.)
- **North-south request/response stays HTTP.** Browser → web-app → web-api and
  iOS → web-api are unchanged in kind — the reasoning under "why north-south stays
  HTTP" below is still exactly why.
- **The clustered Vert.x event bus carries five distinct kinds of traffic**
  *(two at the 2026-08-14 revision; three more added by Phase 21, 2026-08-21)*:
  1. **Request/reply envelopes** on `inventory.svc.*` — the work itself. A
     `BusEnvelope` (package `io.artifexlabs.inventory.api.bus`) names the action and
     its target, carries a typed payload, and binds the request to the acting user:
     their id and principal for attribution, their asserted roles, and the shared
     fabric token. Workers refuse a bad token (401) or a missing role (403) before
     touching the domain.
  2. **After-commit facts** on `inventory.events.*` — publish-only announcements of
     what already happened, payload-identical to the audit trail. Unchanged from the
     original decision.
  3. **Operational status events** on `status.events` (and
     `status.events.<severity>`) — publish-only, best-effort `StatusEvent`s carrying
     BOTH faces of one fact: a machine face (`code` + structured `subject`) and a
     human face (`message` + `detail`), so trouble reaches a person instead of a
     log file. The doorbell, never the record — the audit trail keeps that job.
     They reach frontends through the gateway's authenticated, actor-scoped SSE
     stream, NEVER a bus bridge.
  4. **Printer packets** on `printer.print` / `printer.print-batch` /
     `printer.feed` — `send` with an ACCEPTANCE ack, never a completion claim: the
     printers speak one-way TCP 9100, so "printed" was never a fact anyone
     possessed. The outcome follows on the status plane. Contract:
     `PrintPackets`, beside the envelope in `io.artifexlabs.inventory.api.bus`.
  5. **Internal storage operations** on `storage` — every read and write of the
     backing store, as whole-unit DOMAIN operations (never composable CRUD,
     because two bus messages can never share a database transaction). Unguarded
     by design; see the security model.

  *(Phase 22, 2026-08-22:)* every envelope now also carries a **`requestId`**,
  minted once at the gateway and passed unchanged through forwards, derived
  operations, and printer packets. It is what lets an outcome that arrives long
  after the reply — the only kind a unidirectional printer can give — be traced
  back to the request that caused it, and therefore delivered to the user who
  made it rather than only to an administrator. A wire envelope without one is
  refused: a minted substitute would claim a cause we never saw.
- **The `audit_events` table is the durable log of record.** It is already written in
  the same Postgres transaction as every mutation, which makes it a transactional
  outbox we get for free. Consumers replay/catch-up from it; the fact plane is a
  latency optimization, never a correctness dependency.
- **No hub service, no broker.** The Vert.x bus stays peer-to-peer: `inventory-server`
  is a *service host* whose workers own the domain, NOT a relay that messages pass
  through — the "clearing house" rejected below is still rejected. If consumer needs
  ever exceed what a Postgres cursor sustains (or cross-datacenter fan-out appears),
  the escape hatch is a real broker (Kafka/NATS) — a deliberate future decision, not
  this one.
- **Trust boundary**: external inputs authenticate at the gateway; anything already
  on the bus is considered authenticated, because cluster membership *is* access
  (see the security model below — the fabric token is defense in depth, not the
  perimeter).

The minimum viable consumer is therefore: a Quarkus service with a Postgres
connection, polling a cursor. Joining the bus upgrades it from poll-interval latency
to sub-second push. That is what makes "arbitrary number of services" cheap.

## Why not the alternatives

**Why north-south stays HTTP** (i.e. bus request-reply for browser → web-app →
web-api traffic — still rejected). Those hops carry HTTP semantics the bus cannot:
status codes the UI branches on, content types (`image/png` QRs, raw label bytes),
and streamed asset upload/download (bus messages are fully buffered in memory). The
iOS app can never join a Vert.x cluster, so the HTTP surface must exist anyway; OIDC
and sessions are HTTP-shaped; and cluster membership would become an availability
dependency for every page load.

*Scope note (2026-08-14 revision):* this argument is about the **edge**, and it still
holds — which is why the gateway exists at all. It does NOT apply to the
gateway → worker hop now on the bus: that hop is server-to-server between trusted
cluster members, needs no browser semantics, and deliberately accepts cluster
membership as an availability dependency (no workers, no API). Binary payloads that
do cross it — QR PNGs, asset bytes — ride base64 inside the envelope, accepted for
photo-sized data and called out as a known constraint.

**`inventory-server` as an event "clearing house."** The clustered bus has no center:
members connect peer-to-peer and messages flow producer→consumer directly. A hub JVM
would add a hop and a single point of failure while re-implementing, badly, what the
transport already does (or what a broker would do properly).

**Commands as published events** (mutations entering the system as fire-and-forget
announcements). Callers need the synchronous answer — the created item, its ID, or
the constraint violation. Publish is at-most-once with no reply, so a dropped message
is a silently lost write. And the repo's core invariant — the audit row commits in
the same transaction as the change — dies when the change happens in a consumer
detached from the request.

*This is precisely why the revision used **request/reply**, not publish, for domain
work:* the caller blocks for a real answer (including HTTP-aligned failure codes), a
lost message surfaces as a timeout rather than a phantom success, and the worker runs
the whole mutation — audit row included — in one transaction on the far side. The
`inventory.events.*` plane keeps its original discipline: **facts, not commands**,
published only after commit.

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
| One HTTP tier + bus facts + audit replay | *Originally chosen 2026-08-14 and executed (stages 1–7).* Durable log already exists in-tx; consumers correct even while down; bus optional per consumer; no new stateful infra — all still true, and all retained below |
| **Authenticated HTTP edge + bus request/reply for domain work + the same fact plane (chosen, 2026-08-14 revision)** | Keeps every property of the row above, and makes the bus the integration surface: a new trusted service speaks envelopes instead of re-implementing a client. Costs accepted: cluster membership becomes an availability dependency for the API, binary payloads ride base64, and identity on the bus is asserted rather than re-verified (membership is the boundary) |
| Bus everywhere, INCLUDING the browser edge | Loses HTTP semantics/streaming; iOS excluded; cluster gates page loads — still rejected; the gateway exists for exactly this reason |
| Broker (Kafka/NATS) | Real replay/consumer groups, but new stateful infra duplicating what `audit_events` provides at this scale; revisit on outgrowth |

## Event contract

*This section covers the FACT plane only. Its sibling — the request/reply envelope
contract — lives in `io.artifexlabs.inventory.api.bus` (`BusEnvelope`, `BusActions`
with its action→address→role registry, `Roles`, the typed payload interfaces, and
since Phase 21 the `PrintPackets` printer protocol), documented in that package's
`package-info.java`. The STATUS plane lives beside the fact plane in
`io.artifexlabs.inventory.api.events` (`StatusEvent`/`StatusEvents`/
`StatusPublisher`): one record with a machine face and a human face, identity
stamped at publication so ids and timestamps agree with delivery order.*

Package `io.artifexlabs.inventory.api.events` (in `inventory-api`):

- **Payload**: the serialized `AuditEvent`, plus a version field —
  `{v: 1, id, ts, principal, action, targetId, details?}`. Additive changes only;
  a breaking change bumps `v` and publishes both shapes for a deprecation window.
  `JsonObject` crosses the clustered bus natively; no custom codecs.
- **Addresses**: `publish` (fan-out; never `send`) to `inventory.events` and to
  `inventory.events.<category>`, category = the action prefix
  (`item`, `location`, `asset`, `region`, `user`, `token`, `label`). The action
  vocabulary is the existing audit vocabulary: `item.create/update/delete/contain/
  uncontain/move`, `asset.attach/delete`, `region.create/delete`,
  `user.create/delete/set-admin/identity-link`, `token.revoke`, `label.print`.
  (`location.*` survives only in historical audit rows — locations became items
  with Phase 15's unified containment.)
- **`EventPublisher`**: `void publish(AuditEvent e)` — fire-and-forget, never throws,
  never blocks; ships with `EventPublisher.NOOP`. Mutation success must never couple
  to publication.
- **Consumer contract**: handlers are idempotent and dedupe by event `id`. The
  `principal` field is provenance — a record of who acted — never a credential a
  consumer re-authorizes with (authorization already happened at the HTTP tier).

## Emission semantics: publish after commit

Events publish at the same choke points that build audit rows — the private
`audit(conn, …)` helpers in `PgInventorySystem` / `PgAssetStore` /
`PgRegionSystem` and the auto-commit `PgAudit.record` path (`PgLocationSystem` is
gone; locations became items with Phase 15) — but **after** the
transaction (or statement) completes successfully. Publishing inside the transaction
is rejected: it announces changes that may roll back. This is a dual-write and it is
accepted: if the process dies between commit and publish, the row exists, the bus
message is lost, and reconciliation (below) covers it. Exactly-once emission would
need a relay/CDC daemon that the catch-up protocol makes unnecessary.

## Consumer catch-up protocol

1. `audit_events` gains `seq BIGSERIAL` (indexed; shipped as changeset
   `013-audit-seq.yaml`, since folded into `004-audit.yaml` in the
   `inventory-impl-changeset` module by the schema consolidation).
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
- **Fact-plane payloads are data.** They already flow to the audit UI, so they carry
  no secrets; keep it that way.
- **Status-plane payloads are user-scoped operational detail** *(Phase 21)*: no
  secrets, but they name items, formats, and failures per acting user. Their ONLY
  egress is the gateway's authenticated SSE stream, filtered by actor — a user sees
  events whose `actor` is them, admins additionally see unattributed system faults,
  and the firehose is admin-opt-in only. The bus itself is never bridged to a
  browser or app (the web-app PROXIES the stream precisely so no token reaches the
  browser).
- **The `storage` address is unguarded by DESIGN** *(Phase 21)*: admission (fabric
  token + role) happens exactly once, at the public service verticle that forwards
  the envelope verbatim. That is sound only because membership is the boundary —
  the address must never be reachable from outside the bus, the same invariant
  that keeps 7800/15701 unpublished.
- **Envelope-plane payloads are NOT all inert** *(2026-08-14 revision)*: every
  envelope carries the shared fabric token, and the pre-auth `auth.login`/
  `auth.exchange` actions carry credentials and the exchange claim. This is
  acceptable only because the cluster network is private and internal-only — it is
  the concrete reason ports 7800/15701 must never be published, and the reason
  JGroups transport encryption is the right next hardening step if the cluster ever
  spans hosts.
- **Identity on the bus is asserted, not re-verified.** A worker checks the fabric
  token and the envelope's roles against the action's requirement; it does not
  re-authenticate the named user — that happened at the gateway. Any cluster member
  can therefore speak as any user, which is the direct consequence of "membership is
  trust." The envelope is immutable once built (payload deep-copied at every
  boundary) so an admitted request cannot be altered in flight.
- **Roles are DERIVED, not managed.** There is no role storage anywhere. The
  vocabulary is three constants — `inventory.read`, `inventory.write`,
  `inventory.admin` — and `Roles.rolesFor(user)` maps a user to them from the single
  `InventoryUser.isAdmin()` boolean: every authenticated user reads and writes,
  admins additionally administer. So "managing roles" today means toggling the admin
  flag (`users.set-admin`); there is no way to grant read-only access or revoke write
  without code. **Enforcement is real** (every action declares its required role in
  `BusActions`; `BusGuard` refuses with 403 before any work) — it is only the
  *assignment* side that is a single flag. `rolesFor` is deliberately the one seam:
  real role management would add a `user_roles` table and read it there (plus grant/
  revoke actions), and neither the workers nor the action→role registry would change.

## Staged plan (each stage gated; everything off by default)

*Historical record of how this was rolled out on 2026-08-14, kept as written. Two
stages were revised later the same day by `migrate_to_vertx_eb` — noted inline. Note
that "off by default" describes the rollout: in deployment today the bus is
mandatory (no workers, no API), while `inventory.events.bus` still defaults to
`none` in a bare checkout.*

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
   `io.artifexlabs.inventory.webapi`); the `ApiProxyResource` pass-through and its
   HTTP stub died (nothing left to proxy); `ItemViewsResource` now composes its
   aggregates from the domain beans in-process instead of HTTP self-calls; webapp
   config unchanged (`inventory.web-api.url`); compose runs web-api with the pg +
   printer env on :8081; `inventory-server` is parked (out of the reactor and
   compose; repo + history remain, tagged `before-remove-inventory-server`).
   *Gate: 49 web-api tests green (all migrated domain tests incl. Pg/Testcontainers
   + rewritten views tests) and the full-workspace verify + dev-mode smoke below.*
   **REVISED same day:** `inventory-server` was un-parked as the bus worker host and
   the domain beans moved back into it; web-api kept the REST surface and became the
   authenticated gateway, retaining its own producer copy solely for embedded
   (single-process dev/test) mode.
5. **Reference consumer: `inventory-projector`** — **EXECUTED 2026-08-14** *(as
   `inventory-exporter`; renamed 2026-08-23 — it projects the audit log into a
   derived table, nothing leaves the system)*. New module/repo (:8083):
   `ProjectionLoop` drains `audit_events.seq` from a durable cursor;
   `item.*`/`label.print` land in `projections` exactly once (event-id PK);
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
   329 ms against a 30 s poll interval; projector killed mid-stream missed nothing
   (recovered at the first tick, exactly once).*
   **REVISED same day:** with the bus mandatory rather than opt-in, the overlay was
   merged into `docker-compose.yml` and deleted — the base stack now runs a
   three-member cluster (gateway .11, server .12, projector .13) on the same
   internal-only static-IP network. `docker-compose.release.yml` (versioned
   images — public Docker Hub `artifexlabs` since 2026-08-21) is the only overlay
   today; see [deploy/DEPLOYMENT.md](deploy/DEPLOYMENT.md).
7. **CI + runbook** — **EXECUTED 2026-08-14** (CI gate lands with the next push).
   `ClusteredBusTest` — two clustered Vert.x nodes over loopback, same stack as the
   overlay — runs inside plain `mvn verify`, so CI exercises the clustered fabric
   on every build. RUNBOOK gains the events/cluster section: ports, split-brain
   symptoms, "a consumer is just a cursor" recovery. NOTE for the eventual push:
   `inventory-projector` must be added to the `SUBMODULE_TOKEN` fine-grained PAT's
   repository list or CI checkout will fail. *(Resolved: the repos are public and
   CI checks everything out with the default token.)*

## Risks and open unknowns

- **Cluster manager under GraalVM native** is unproven here — gated at stages 3/6,
  JVM-container fallback documented above.
- **Dual-write window** (commit-then-publish): mitigated by reconciliation; accepted.
- **The audit vocabulary becomes a public contract.** Action names and `details`
  shapes need the `v`-field discipline once a consumer exists.
- **Idempotency is a contract, not a mechanism** — stated in the events package
  javadoc, enforced in the projector's tests.
- **Memory mode never supports cross-process consumers** (per-JVM state, no durable
  log) — pg mode only, matching the existing constraint.
- ~~**Consolidation ripples**~~ — swept twice (stage 4, then the revision): PLAN.md,
  RUNBOOK, compose, and the Justfile now describe the gateway + worker topology, and
  [deploy/DEPLOYMENT.md](deploy/DEPLOYMENT.md) is the deploy method of record.
- **The bus is now an availability dependency for the API** *(revision)*: with
  workers remote, a partition means gateway requests fail 503 — request/reply has no
  store-and-forward. Deliberate: the alternative was a gateway that silently accepts
  work it cannot do. The fact plane keeps its old property (partitions lose nothing;
  consumers reconcile from the table).
- **Envelope payloads are fully buffered** *(revision)*: asset bytes and QR PNGs
  cross base64 inside the envelope. Fine for photo-sized data; a large-file feature
  would need a side channel (object store URL in the envelope) rather than bigger
  messages.
- **Two producer copies** *(revision)*: `InventoryBackendProducer` exists in both
  `inventory-server` and `inventory-web-api` (the latter only for embedded
  single-process mode). They must stay in step — a printer or storage option added
  to one belongs in the other. *(Re-confirmed by Phase 21: the status-publisher
  wiring had to land in both.)*
- **Manifest ingestion rides one envelope** *(Phase 22)*: a medium's whole
  file listing arrives as a single `data.replace-manifest` message, because
  splitting it would tear the transaction that makes a manifest a snapshot.
  Envelope payloads are fully buffered (above), so a listing large enough to
  strain that is the recorded trigger for chunked staging on the storage side —
  not for making the operation composable.
- **Storage isolation adds a hop** *(Phase 21)*: every data access crosses the bus
  to `StorageVerticle` — in-process in embedded mode, the network in remote mode.
  Accepted for single-flight storage discipline; chatty BFF views may eventually
  want batch operations added to the storage vocabulary. The companion rule is
  absolute: storage operations are WHOLE units of work, because two messages can
  never share a transaction — and meaning that rides on exception types does not
  survive the message boundary either (`catalog.create-item`'s 409→500 regression
  was the lesson; the translation now lives on the storage side).
- **Role granularity is a single boolean** *(revision; see the security model)*: the
  bus enforces three roles rigorously, but every user gets read+write and only the
  admin flag varies. A read-only or per-location role needs stored roles behind
  `Roles.rolesFor` — cheap to add, but it is NOT there today, so do not read the
  role checks as evidence of fine-grained authorization.
- **The fabric token is a single shared secret** with no rotation story beyond
  redeploying gateway and workers together (`INVENTORY_BUS_TOKEN`). Acceptable while
  membership is the real boundary; revisit alongside JGroups transport encryption.
