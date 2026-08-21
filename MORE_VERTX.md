# MORE_VERTX — pushing the verticle architecture deeper

*Written 2026-08-21. STAGING document (the [UPC_CODE.md]/MAVEN_RELEASES.md
lifecycle): reviewed here, then moved into [PLAN.md](PLAN.md) as milestones
when accepted/scheduled, at which point this file retires.*

## The three asks (owner, 2026-08-21)

1. **Printers become verticles.** The vendor printer implementations stop
   being directly-called objects; callers send a packet carrying everything
   needed to produce a label, and the printer verticle may request further
   data over the bus if the packet isn't enough.
2. **All data IO isolates into a storage verticle.** CRUD is *requested* of
   the storage verticle; responses carry whatever the caller needs,
   deserialized. Nothing else touches the database implementation (or any
   other storage mechanism) directly.
3. **Errors propagate to an event-bus topic** that reaches the mobile apps
   and the web-app in a timely fashion — users learn about failures from the
   UI, not from log files. Both frontend kinds will need to maintain a
   connection for this, which is itself a change.

**The unifying requirement**: every status event is *sendable to the
consumer* in BOTH forms at once — a detailed human-readable notification
AND a structured message machinery can parse. One event, two audiences,
never two publications that can drift apart.

## Where we are (grounded 2026-08-21)

- The bus fabric already exists and is the app's spine: clustered Vert.x
  event bus, `BusEnvelope` + `BusActions` (role-checked WRITE/READ),
  `ServiceVerticle`/`BusGuard` (fabric token + acting user's role),
  deployed identically by inventory-server's `BusHost` and web-api's
  embedded mode (`inventory.bus.workers=embedded|remote`).
- `BusWorkers.deploy` constructs eight verticles, **each holding direct
  references to backends** via `BackendServices`: `ItemsVerticle(guard,
  s.inventory())`, `LabelsVerticle(guard, s.inventory(), s.printer(),
  s.auditSink())`, and so on. The verticle *boundary* exists; backend
  *isolation* does not — every verticle is its own storage caller.
- Printers are CDI-constructed in the server/web-api producers and handed
  into `LabelsVerticle`, which calls `printer.printLabel(...)` in-process.
  Since `split-out-printers-step-1`, the vendor code lives in its own
  modules (`inventory-impl-brother`, `inventory-impl-zebra`) over a
  dependency-free `inventory-impl-printer-common` — the module seam for
  per-vendor verticles is already cut.
- `VertxEventPublisher` already publishes committed audit facts to a bus
  topic (the exporter's push nudge) — precedent for topic-shaped fan-out,
  but audit facts are *successes by definition* (after-commit). Failures
  today go to logs and HTTP error responses only.
- Known transport truth that shapes ask 3: the Brother's port 9100 is
  unidirectional — `printed:true` means "bytes accepted", and the honest
  failure signals we DO have (refusals: unknown format, tape mismatch, no
  scannable QR, unreachable printer) currently die in logs as `warn`s.

## Design

### The StatusEvent envelope (asks 1–3 all emit these)

One record, both audiences, published to a topic — never request/reply:

```json
{
  "id":            "01M0...",            // ULID, event identity + ordering
  "ts":            "2026-08-21T14:03:22.123456Z",
  "severity":      "error | warning | info",
  "code":          "printer.tape-mismatch",   // MACHINE key, stable, namespaced
  "source":        "printer.brother",         // emitting verticle
  "subject":       { "itemId": "01M0...", "format": "standard" },  // structured params
  "message":       "Label refused: format 'standard' needs 12 mm tape but 24 mm is loaded",
  "detail":        "…optional longer human text…",
  "correlationId": "…the originating BusEnvelope request id…",
  "actor":         "…user id that caused the action, when attributable…"
}
```

- `code` + `subject` are the machine face; `message` + `detail` the human
  face. Emitting helpers take both at the same call site so they cannot
  drift.
- `correlationId` ties an async failure back to the HTTP request / user
  action that caused it — the web-app can say "your print failed", not
  just "a print failed".
- **Relation to audit**: unchanged and non-overlapping. Audit = committed
  domain facts, durable, the record. StatusEvents = operational outcomes
  (mostly failures/warnings), best-effort, for humans-now and
  machines-watching. An action may emit both (a failed print emits a
  StatusEvent; a successful one audits as today).

### Topics and addresses (extending the existing vocabulary)

```
status.events                 publish-only topic, all StatusEvents
printer.print                 send: one label packet -> ack {accepted}
printer.print-batch           send: batch packet    -> ack {accepted, count}
printer.feed                  send                  -> ack
storage.<aggregate>.<op>      send: CRUD/domain ops -> reply payload
```

- `printer.*` addresses are claimed by whichever vendor verticle is
  deployed (config selects exactly one, as `inventory.printer` does now);
  the logging printer gets a verticle too, so the address always answers.
- Acks are *acceptance*, not completion: the printer verticle replies as
  soon as the packet is valid and queued, then reports the outcome as a
  StatusEvent (success `info`, failure `error`). This matches the 9100
  reality — completion was never knowable — and stops HTTP requests from
  hanging on hardware.

### Ask 1 — printer verticles

- `inventory-impl-brother` and `inventory-impl-zebra` each gain a
  `PrinterVerticle` wrapping their existing `LabelPrinter` impl (the
  interface survives as the in-module seam; the BUS becomes the only
  cross-module caller). `printer-common` gains the shared packet/ack/
  StatusEvent emitting base (a `PrinterVerticle` skeleton) — it stays
  dependency-light (vertx-core joins; still no impl-core dependency).
- **The print packet is self-contained by default**: item snapshot
  (ItemFactory JSON — the wire form that already exists), scanUrl, format,
  optional pre-rendered qrPng (Zebra's path), halfCut for batches. The
  Brother renders its own module-exact QR from scanUrl exactly as today.
- **The fetch-back escape hatch** (owner ask): a packet MAY carry only
  `itemId`; the printer verticle then requests `storage.items.get` itself.
  Kept as the exception, not the rule — self-contained packets keep the
  printer deployable where storage isn't (a future print-station node).
- `LabelsVerticle` sheds the `LabelPrinter` reference and becomes the
  orchestrator it already half is: resolve item, build packet, `send` to
  `printer.print`, audit on ack. Server/web-api producers stop
  constructing printers; the vendor modules' verticles deploy from
  `BusWorkers` (config-selected).

### Ask 2 — the storage verticle

- **The load-bearing constraint: bus messages cannot share a database
  transaction.** The storage verticle therefore exposes DOMAIN OPERATIONS
  (create-item-with-identity, attach-asset, containment-change …), never
  row-level CRUD a caller would compose — composition across messages
  would tear the tx boundaries the Pg impl currently guarantees
  in-process. The existing `BusActions` vocabulary is already
  operation-shaped, which is why this is tractable at all.
- Shape: `StorageVerticle` (in impl core) is constructed with
  `BackendServices` and becomes the ONLY holder of `InventorySystem`,
  `AssetStore`, `UserStore`, `TokenService`, `RegionSystem`,
  `AuditReader`. The other verticles (Items, Assets, Regions, Users,
  Tokens, Audit, Catalog, Labels) drop their backend constructor args and
  speak `storage.*` instead — they keep their public `items.*` etc.
  addresses and their role checks, becoming pure protocol/orchestration.
- Replies are the deserialized wire forms that already exist (ItemFactory
  JSON and friends) — callers never see storage types.
- Memory/Pg twins both live behind the same verticle; the parity tests
  gain a bus-level layer (same operation, either backend, same reply).
- Honest consequence: one more in-process hop per data access in embedded
  mode, a network hop in remote mode. Accepted — it buys single-flight
  storage discipline, one place for tx/retry policy, and the option to
  scale/relocate storage independently later.

### Ask 3 — status topic to the frontends

- Emitters: the printer verticles (every refusal that is a `log.warn`
  today becomes `warn`/`error` StatusEvents — tape mismatch, unknown
  format, no scannable QR, unreachable printer), the storage verticle
  (constraint violations, backend-down), `BusGuard` denials, and the
  gateway itself (5xx it generated).
- **Frontend channel: SSE from inventory-web-api** (recommended over a
  raw SockJS bus bridge — the bus stays sealed; bus membership is access,
  VERTICLES.md). `GET /api/v1/events/stream` (SSE, authenticated):
  web-api subscribes to `status.events` once and fans out per connection,
  FILTERED: a user receives events whose `actor` is them, admins may opt
  into all. The token/role machinery already at the gateway does the
  scoping.
- Delivery semantics v1: live + shallow replay. The gateway keeps a small
  in-memory ring (say 100 events / 15 min) per scope so a reconnecting
  client (SSE `Last-Event-ID`) misses nothing recent. NOT durable, NOT
  guaranteed — the audit trail remains the record; this is the doorbell.
- Web-app: an `EventSource` in the shell layout + a toast/banner region
  (severity-styled, `message` shown, `detail` expandable) — the first
  live element in the UI (and a Phase 18 design input).
- iOS (and Android when real): maintain the SSE connection while
  foregrounded; surface as in-app banners. **Store push (APNs/FCM) for
  backgrounded apps is explicitly out of scope here** — it's a real
  follow-on with its own infrastructure, and this plan's contract (the
  topic + dual-form events) is exactly what such a bridge would consume.

## Module architecture: domain and bus layers as SEPARATE modules (owner-accepted 2026-08-21)

The verticle/domain boundary becomes a MAVEN boundary, so the build — not
review — enforces the isolation:

```
inventory-impl-root
  inventory-impl-printer-common   (exists) layouts + 9100 wire, dependency-free
  inventory-impl                  (domain) impls, memory twins, catalog, Gtin/Ulid/QrCodes
  inventory-impl-changeset        (exists) the schema
  inventory-impl-pg               (domain) Pg backends
  inventory-impl-brother          (domain+verticle) driver AND its PrinterVerticle
  inventory-impl-zebra            (domain+verticle) driver AND its PrinterVerticle
  inventory-impl-bus       (NEW)  the EIGHT verticles, ServiceVerticle/BusGuard,
                                  BusEnvelope + Default* wire types, BusWorkers
                                  — depends on api + vertx-core ONLY
```

- **The enforced rule, stated precisely**: domain modules carry NO event
  bus, NO verticle lifecycle, NO envelope types (compiler-checked: no
  inventory-impl-bus dependency, and core/pg lose vertx-core where it was
  only there for the bus). "Vertx-free domain" is deliberately NOT the
  rule — the Pg data plane IS the vertx pg-client and stays that way.
- **The bus module is interface-pure**: measured 2026-08-21, the eight
  verticles import exactly five non-api impl types (Gtin, Ulid, QrCodes,
  UserStore, CatalogImages) and zero storage impls. UserStore (an
  interface) promotes to api; the small utilities either promote or ride
  behind api seams — after which inventory-impl-bus cannot see Pg vs
  memory even if it tries.
- **Per-verticle module PAIRS were considered and rejected**: ~16 modules
  delivering the identical compiler guarantee the single layer boundary
  gives, at the cost of poms, BOM entries, and a reactor nobody holds in
  their head. The one future exception: a print-station node wanting
  driver-only vs verticle-only vendor artifacts — revisit the vendor
  modules IF that topology becomes real.
- Tests layer with the modules: pure-domain tests (and the Phase 20 parity
  TCK target) in the domain modules; protocol/verticle unit tests plus
  bus-level integration (including the bus parity layer) in
  inventory-impl-bus.

## Execution log

- **Step 1 DONE 2026-08-21** (feature `more-vertx-status-fabric`): the
  StatusEvent fabric exists and every refusal path emits.
  - api: `StatusEvent` (the dual-form record — the builder demands `code`
    AND `message` at one call site so the faces cannot drift),
    `StatusEvents` (topic + wire, mirroring `InventoryEvents`),
    `StatusPublisher` (fire-and-forget, NOOP default).
  - Identity is stamped at PUBLICATION, not construction, so ids/timestamps
    agree with delivery order; `VertxStatusPublisher` does the stamping and
    swallows failures by contract.
  - Emitters wired: Brother (tape-mismatch, unknown-format,
    no-scannable-qr, print-failed, batch-refused, feed-failed), Zebra
    (unknown-format, print-failed), `BusGuard` (bad-fabric-token,
    forbidden). Every one of these was previously a `log.warn` that died in
    a file.
  - `StatusLogVerticle` deploys with the workers so the topic is never
    write-only.
  - Tests: 6 api (both-faces enforcement, publication stamping, wire
    round-trip per severity), 5 Brother emission tests asserting exactly
    one event with both faces AND the structured params.
  - **Known gap**: `correlationId` is unpopulated — `BusEnvelope` has no
    request id yet. Printer events are likewise unattributed (the printer
    does not know who asked), which is precisely what step 4's packets fix.
    Until then, unattributed events are admin-visible (see step 2).
- **Step 2 GATEWAY DONE 2026-08-21**, web-app surfacing pending:
  - `StatusStreamBroadcaster` (@ApplicationScoped) subscribes to the topic
    ONCE at startup and fans out per connection; `EventsResource` exposes
    `GET /api/v1/events/stream` (SSE), already covered by the blanket
    bearer-token filter. SSE event NAME = severity, data = the event JSON.
  - Scoping (a security boundary, so tested without a server): a user sees
    events whose `actor` is them; admins additionally see unattributed
    system faults, and `?all=true` gives admins the firehose — the flag is
    IGNORED for non-admins. Replay is filtered by the identical rules.
  - Reconnect: `Last-Event-ID` replays the gap from a bounded ring (100
    events / 15 min); an unknown cursor replays NOTHING rather than
    implying completeness it cannot promise.
  - Tests: 8, covering crossed-actor privacy, admin-only firehose,
    unattributed routing, gap replay, replay leak-proofing, dead-client
    eviction, ring bounding.
  - **Browser-token note**: `EventSource` cannot set an Authorization
    header, so the browser must NOT connect to this endpoint directly. The
    web-app (a BFF holding the session server-side) proxies the stream to
    the browser — which also keeps tokens out of URLs. That proxy plus the
    toast UI is the remaining half of step 2.

## Staged steps (each a milestone-sized chunk)

1. **StatusEvent fabric** — the record + emitting helper in api/impl, the
   `status.events` topic, and emission from every existing refusal/failure
   path (printers, guard denials, storage errors). No consumers yet beyond
   a log subscriber; immediately useful for tests. *Small.*
2. **SSE gateway + web-app surfacing** — the authenticated stream endpoint
   with actor-scoping and the reconnect ring; web-app toasts. First
   user-visible payoff. *Medium.*
3. **inventory-impl-bus extraction** — the module architecture above:
   verticles + envelope machinery move to the new module; UserStore and
   the utility seams promote; domain modules drop bus knowledge. Pure
   mechanical move done BEFORE the verticle rework so steps 4–5 rewire
   each verticle once, in its final home. *Medium.*
4. **Printer verticles** — packet schema in printer-common, per-vendor
   verticles in the vendor modules, LabelsVerticle re-plumbed, producers
   stop constructing printers, fetch-back path. Hardware smoke re-run
   (print discipline applies). *Medium.*
5. **Storage verticle** — `storage.*` operations, backends move behind it,
   every other verticle re-plumbed to speak bus-storage; bus-level parity
   tests in inventory-impl-bus. The largest and riskiest step; do LAST,
   with the StatusEvent fabric already there to watch it. *Large.*
6. **Mobile connection** — iOS SSE client + banners (Android when the app
   exists). *Small-medium, gated on step 2.*

Order rationale: 1 → 2 give observable value fast and instrument
everything; 3 makes the isolation structural before anything is rewired;
4 exercises the packet/ack/StatusEvent pattern on the smallest seam; 5
rides on all of it.

## Costs and risks (recorded up front)

- **Hop tax**: embedded mode pays an in-process bus hop per storage call;
  remote mode pays the network. The envelope/serialization path is already
  proven, but chatty call sites (BFF views composing several reads) may
  want batch operations added to the storage vocabulary.
- **Transaction discipline**: the domain-operation rule must be enforced by
  review — one composed-CRUD slip reintroduces the torn-tx bug class
  invisibly. The parity TCK (Phase 20 step 0) is the natural place to pin
  operation atomicity.
- **Packet size**: item snapshots + optional qrPng ride the bus; batches
  multiply it. The clustered bus has handled label batches since item 10,
  but batch packets should carry the composed requests, not N full
  snapshots of the same item.
- **Event scoping is a security surface**: the SSE fan-out must filter by
  actor/role at the gateway; leaking admin-grade operational detail to
  every user is the failure mode. The bus itself stays unexposed.
- **Two frontends to touch** (three with Android later) for ask 3's value
  to land; until step 2 ships, StatusEvents are invisible to users.
- Printer verticles change the failure UX: HTTP callers get fast "accepted"
  instead of waiting on hardware — tests asserting synchronous print
  results (204-means-printed) need rethinking toward ack + event.

## Verification (per step, when executed)

1. Unit: every refusal path emits exactly one StatusEvent with both faces
   populated; envelope schema round-trips.
2. SSE: two users, crossed actions — each sees only their own events;
   reconnect with `Last-Event-ID` replays the gap; admin opt-in sees both.
3. Extraction: full reactor green; `mvn dependency:tree` shows
   inventory-impl-bus without core/pg, and domain modules without
   inventory-impl-bus; jandex/Quarkus archives intact in the apps.
4. Fake-printer smoke (`just smoke-fake-printer`) passes over the bus path;
   a tape-mismatch print returns accepted:false-or-refusal AND lands as a
   StatusEvent in the SSE stream; then the hardware gates re-run.
5. Full parity suite green with every verticle speaking `storage.*`; the
   torn-tx canary (create-with-identity under injected failure) proves
   atomicity survived; `just verify` + stack smoke.
6. iOS: banner appears within ~2 s of a forced printer refusal while the
   app is foregrounded.

[UPC_CODE.md]: PLAN.md
