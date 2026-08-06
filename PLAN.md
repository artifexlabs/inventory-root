# Inventory System — Plan

*Derived from [README.md](README.md). Decisions recorded 2026-08-05.*

## Context

The README describes a multi-module inventory system handling both physical objects and
data (physical media, remote/network/cloud storage; mutable or immutable; archives as
sub-containers). Containers have locations (name + lat/long), and any item becomes a
container by putting things in it. Every object carries a unique id small enough for a
compact QR code. The system exposes a well-known API format (OpenAPI), a token-secured
API, a Google-auth webapp with an admin section, a full audit trail, CRUD with attached
assets (pictures/audio) and descriptions, par values, label-printer integration, and —
eventually — iOS/Android clients.

## Decisions (locked)

| Decision | Choice | Rationale |
|---|---|---|
| Runtime | **Quarkus from the start** | Equal native-image runtime power to hand-rolled GraalVM, but Quarkus extensions maintain the native metadata for the whole dependency graph — the cheapest way to keep native builds working release-over-release (a day-2 concern, which the README prioritizes). Quarkus runs on Vert.x, so the verticle/event-bus model survives. |
| Database | **PostgreSQL** | Relational (README requirement), first-class Liquibase support, reactive client, JSONB for flexible item attributes. `vertx-mongo-client` is dropped. |
| Build layout | **Multi-repo + local aggregator** | The five repos stay independently versioned/publishable; an aggregator pom at the workspace root (untracked, or its own tiny repo) gives a one-command local build in dependency order. |
| IDs | **ULID strings** | 26 chars, lexically sortable (index-friendly), compact enough for small QR codes. QR encodes `https://<host>/i/{id}`. `Item.getId()` stays `String`. |
| Label/QR rendering in native | **`quarkus-awt`** *(revised 2026-08-06; supersedes the pure-PNG-encoder decision of 2026-08-05)* | Labels will compose text and possibly other images alongside the QR — that is real Java2D (`Graphics2D`, fonts), which a bare PNG encoder cannot do. quarkus-awt makes AWT work in native images with Quarkus maintaining the metadata. Costs accepted: native images are Linux-only (the deploy target is Linux containers anyway) and the container image must carry fonts + fontconfig. macOS development is unaffected — headless AWT works fully on the JVM, so all dev and tests run on the Mac; native verification happens by container-building and container-running. If labels ever turn out to be QR-only after all, the pure-JDK 1-bit PNG encoder over zxing's `BitMatrix` remains the recorded simplification option. |

## Architecture

- **Quarkus 3.x (latest LTS)** everywhere a process runs. GraalVM native container images
  via `quarkus-container-image-*` and the `native` profile; JVM-mode containers remain for
  dev/debug.
- **Contracts live in `inventory-api`, framework-light.** Plain Java domain interfaces +
  DTOs + JSON wire contracts (the existing `ItemFactory.serialize`/`deserialize` and its
  tests are the seed). Service interfaces return `CompletionStage<T>` — neutral, adapts
  trivially to Mutiny `Uni` (Quarkus) or Vert.x `Future`. The **Vert.x codegen
  (`@ModuleGen`/`@ProxyGen`/`@VertxGen`) and service-proxy machinery is removed**: under
  Quarkus, inter-service calls use the managed Vert.x event bus (`@ConsumeEvent`) with the
  same JSON payloads, and cross-language consumers use the OpenAPI contract instead of
  generated proxies.
- **Topology:** Quarkus apps as containers communicating over the clustered Vert.x event
  bus (Quarkus manages the Vert.x instance). One service per container by default; where
  that becomes inconvenient (README's day-2 caveat), consumers are plain CDI beans and can
  be co-located in one app without code changes.
- **Persistence:** `quarkus-reactive-pg-client` (Mutiny). All schema via **Liquibase**
  changesets (in `inventory-impl`), runnable at startup for dev and via CLI for controlled
  day-2 migrations; every changeset gets a rollback.
- **Transactions:** every mutation is transactionally complete; the audit row is written
  in the same transaction as the change. Cold/warm restart safety comes from Postgres +
  idempotent Liquibase + stateless services.
- **Audit trail:** `AuditEvent` / `AuditSink` interfaces in `inventory-api`; append-only
  Postgres table implementation in `inventory-impl`; surfaced read-only in the webapp.
- **Auth:** webapp frontend = Google OIDC (`quarkus-oidc`). API = bearer tokens. Admin
  section manages users and tokens. `InventoryUser` / `TokenService` interfaces in
  `inventory-api`.

## Module responsibilities

| Module | Role |
|---|---|
| [inventory-parent/](inventory-parent/) | Parent pom: imports Quarkus BOM, plugin/dependency management, shared config. Still parents off `ibparent`. |
| [inventory-api/](inventory-api/) | Domain model, service interfaces, JSON wire contracts, audit/auth/user interfaces, constants. Depends on `vertx-core` only for `JsonObject`/`JsonArray`. |
| [inventory-impl/](inventory-impl/) | Default implementations: Postgres repositories, transactional `InventorySystem`, audit sink, Liquibase changelogs. CDI beans, minimal Quarkus coupling. |
| [inventory-server/](inventory-server/) | Quarkus service host: REST resources exposing `InventorySystem`, OpenAPI (`quarkus-smallrye-openapi`), event-bus consumers, token auth, health probes. |
| [inventory-webapp/](inventory-webapp/) | Quarkus app: token-secured API part (OpenAPI), UI part consuming it, Google OIDC login, admin section, audit views. |

## Roadmap

### Phase 0 — Build foundation
- Aggregator pom at workspace root listing all five modules (untracked or tiny separate repo).
- `inventory-parent`: import `quarkus-bom` in dependencyManagement; align/retire the
  standalone Vert.x version property; keep `ibparent` as parent.
- Skeleton poms for `inventory-impl`, `inventory-server`, `inventory-webapp`.

### Phase 1 — Domain contracts, persistence, server skeleton *(first milestone — detail below)*

### Phase 2 — Webapp *(first increment = second milestone — detail below)*
- API part: token-secured REST with published OpenAPI document.
- UI part rendering from the API; Google OIDC login; admin section (user + token CRUD);
  audit trail views. Every admin/inventory mutation audited.
- First increment (second milestone): vanilla UI with credential login granting real
  tokens, item browsing with two-way containment navigation, and move/add-to-container
  actions.

### Phase 3 — Rich inventory
- Assets: pictures/audio attached to items (storage decision — object store vs. Postgres —
  recorded when taken); descriptions.
- Par values: min/max/current on-hand; per-location instances of an item.
- Locations as first-class: name + lat/long; containers reference locations.
- Data-item modeling completed: media kinds (physical media, remote/cloud), mutability
  flags, archives as sub-containers.

### Phase 4 — QR and labels
- ULID → QR generation (zxing); label-printer connector API; scan deep links that resolve
  `/i/{id}` to webapp or (later) mobile app.

### Phase 5 — Native and deploy
- **AWT-in-native via `quarkus-awt`** (per the label/QR rendering decision above): add
  the extension to inventory-server; container image gains fonts + fontconfig (e.g.
  dejavu) so text renders in native; macOS flow is
  `mvn verify -Dnative -Dquarkus.native.container-build=true`, then run the built
  container and drive the standing smoke flow (login, CRUD, `qr.png`, `print-label`).
  Gate: the `QrAndLabelTest` decode round-trip stays green in JVM tests, and the same
  check is repeated with curl+zxing against the running native container.
- Native-image builds for server and webapp; container images; compose/nomad/k8s
  manifests; clustered event-bus configuration; cold/warm restart drills; backup/restore
  and migration runbooks (day-2).

## First milestone (Phase 1, implementable detail)

1. **`inventory-api`** — de-codegen and extend:
   - Delete the `@ModuleGen` from `package-info.java`; remove `@ProxyGen`/`@VertxGen` from
     [InventorySystem.java](inventory-api/src/main/java/org/lawfulevil/inventory/api/InventorySystem.java);
     drop `vertx-codegen*`, `vertx-service-proxy`, `vertx-auth-*`, `vertx-mongo-client`,
     rx-java3 test deps from the pom.
   - `InventorySystem` methods return `CompletionStage<...>`; add `deleteItem`,
     `getItem(id)`.
   - Add interfaces: `Location` (name, lat/long), data-media modeling on `Item` (kind,
     mutability, archive), `AuditEvent`/`AuditSink`, `InventoryUser`/`TokenService`.
   - Extend `Item` with optional `description` and location reference; extend
     [ItemFactory](inventory-api/src/main/java/org/lawfulevil/inventory/api/ItemFactory.java)
     and [DefaultItem](inventory-api/src/main/java/org/lawfulevil/inventory/api/DefaultItem.java)
     to match. The existing 5 round-trip tests are the regression base; grow them with the
     model.
2. **`inventory-impl`** — revive:
   - New pom (parent `inventory-parent`); delete the stale pre-refactor
     [ItemImpl.java](inventory-impl/src/main/java/org/lawfulevil/inventory/ItemImpl.java).
   - `PgInventorySystem` implementing `InventorySystem`: transactional writes, audit row
     per mutation, ULID generation on create.
   - Liquibase: `db/changelog-master.yaml` + initial changesets (items, containment,
     locations, audit, users/tokens), each with rollback.
   - Testcontainers-Postgres integration tests for CRUD + audit + containment.
3. **`inventory-server`** — stand up:
   - New pom; Quarkus app exposing `InventorySystem` over REST; OpenAPI at `/q/openapi`;
     bearer-token filter (static dev token initially); health/readiness; Dev Services
     Postgres for local `quarkus dev`.
4. **Aggregator**: `mvn clean verify` from the workspace root builds api → impl → server green.

## Second milestone (first increment of Phase 2, implementable detail)

*Added 2026-08-05. Goal: a working, relatively vanilla web UI over inventory-server —
login grants a real token, items browse with containment navigation both directions,
and items can be moved into / added to containers from the UI.*

1. **`inventory-api`** — containment as first-class operations (stops the UI doing
   read-modify-write on whole items):
   - `InventorySystem` gains `getContainersOf(String itemId)` (the containers an item is
     in — the reverse link the UI needs), `addToContainer(String containerId, String
     itemId)`, `removeFromContainer(String containerId, String itemId)`, and
     `moveToContainer(String itemId, String targetContainerId)` (= remove from all
     current containers + add to target, one transaction).
   - `TokenService` is unchanged; `InventoryUser` gains nothing — credentials live in
     storage, not on the interface.
2. **`inventory-impl`**:
   - Implement the four containment operations in `InMemoryInventorySystem` and
     `PgInventorySystem` (Pg: single transaction + audit rows `item.contain`,
     `item.uncontain`, `item.move`).
   - `InMemoryTokenService` and `PgTokenService` implementing `TokenService`: tokens are
     ULIDs persisted in the existing `api_tokens` table; validation rejects revoked
     tokens.
   - Liquibase changeset 007: add `password_hash` to `users`; seed a configurable admin
     user. Password hashing via BCrypt (`quarkus-elytron-security` bcrypt utilities or
     `at.favre.lib:bcrypt` — decide at implementation, record in commit).
   - `UserStore` (impl-level, not api): lookup by email, verify password → used by login.
3. **`inventory-server`** — token-granting login (replaces the static-token stopgap):
   - `POST /api/v1/auth/login` `{email, password}` → verifies against `UserStore`,
     issues a token via `TokenService`, returns `{token, user}`. Unauthenticated path.
   - `POST /api/v1/auth/logout` revokes the presented token.
   - `BearerTokenFilter` validates via `TokenService` (memory mode keeps a seeded dev
     user/token so tests and `quarkus dev` still work out of the box).
   - Containment endpoints: `GET /api/v1/items/{id}/containers`,
     `PUT /api/v1/items/{containerId}/contained/{itemId}` (add),
     `DELETE /api/v1/items/{containerId}/contained/{itemId}` (remove),
     `POST /api/v1/items/{itemId}/move-to/{containerId}` (move).
4. **`inventory-webapp`** — vanilla UI, server-rendered Qute + minimal vanilla JS (no
   frontend framework):
   - Quarkus app with a REST client to inventory-server (`inventory.server.url` config);
     the browser only ever talks to the webapp (no CORS surface). The token from login is
     held in an HTTP-only session cookie server-side.
   - `/login`: plain form → webapp posts to server `/api/v1/auth/login`; failure re-renders
     with an error; success redirects to `/items`.
   - `/items`: table of all items (name, type, quantity, location); each row links to
     `/items/{id}`.
   - `/items/{id}`: item detail; contained items listed as links (`/items/{childId}`);
     a "containers" section lists every container this item is in, each a link back —
     containment navigable in both directions.
   - Move/add controls on the detail page: a container picker (dropdown of container-
     capable items) with "Add to container" and "Move to container" buttons calling the
     new server endpoints; "remove from this container" next to each parent link.
   - Google OIDC, admin section, and audit views remain the rest of Phase 2 — this
     milestone's login is the credential/token flow those will layer onto.
5. **Tests**: containment-operation tests in impl (both backends); auth flow tests in
   server (login issues token, bad password 401, revoked token rejected, containment
   endpoints CRUD); webapp `@QuarkusTest` with a mocked/stub server client covering
   login redirect, items render, and a move action.

## Third milestone (Phase 2: admin, audit views, item CRUD UI)

*Added 2026-08-05. No external dependencies.*

1. **api**: `AuditReader` (recent + by-target queries), `TokenInfo` record, and
   `TokenService.tokensFor(userId)` so the audit trail and issued tokens become readable.
2. **impl**: `InMemoryAuditSink` doubles as reader; `PgAuditSink`/`PgAuditReader`;
   `UserStore` gains `list`/`delete`/`setAdmin`; token listing in both TokenServices.
3. **server**: filter stashes the authenticated user; `/api/v1/admin/*` (user CRUD,
   admin flag, token list/revoke) enforced admin-only with 403 otherwise; `/api/v1/audit`
   (recent = admin-only, per-target = any authed user); every admin mutation audited
   (`user.create`, `user.delete`, `user.set-admin`, `token.revoke`).
4. **webapp**: `/admin` (users table, add user, admin toggle, delete, token revoke) gated
   on the session user's admin flag; `/audit` recent-events view; item history section on
   the detail page; item create/edit/delete forms (name, display name, type, description,
   quantity, weight, dimensions).

## Fourth milestone (Phase 2: Google OIDC)

*Blocked input: a Google Cloud OAuth client (id + secret + redirect URI) — wiring is
built and tested with OIDC disabled by default until credentials exist.*

1. **server**: `POST /api/v1/auth/exchange` — trusted webapp-to-server call (shared
   secret header) mapping a Google-verified email to a user and issuing a token via the
   same `TokenService` flow. Provisioning policy config `inventory.oidc.provision`:
   `invited` (default: email must already exist) or `auto` (create on first login).
2. **webapp**: `quarkus-oidc` (Google provider) guarded route; successful OIDC callback
   exchanges the verified email for an API token and enters the normal session flow;
   "Sign in with Google" button on /login. Password login remains.
3. OIDC stays disabled (`quarkus.oidc.tenant-enabled=false`) until real credentials are
   configured, so builds and tests never need Google.

## Fifth milestone (Phase 3: rich inventory)

*Added 2026-08-05. Decisions taken here:*
- **Asset storage: Postgres bytea** (memory map in memory mode). Keeps day-2 to one
  datastore with one backup/restore story; revisit an object store only if asset volume
  demands it.
- **Per-location instances: modeled as separate items.** An "instance" of a thing at
  another location is simply another item (same name/type, its own id/quantity/location).
  No structural instance table until real usage proves the simple model wrong.
- Data-item modeling was already complete (kind, mutability, archive; archives contain
  via ordinary containment) — no changes.

1. **api**: `ParValues` (min/max on-hand) optional on `Item` (current on-hand is
   `quantity`); `AssetInfo` + `AssetStore` (store/get/list/delete, bytes + metadata);
   `LocationSystem` (list/get/create/delete) over the existing `Location` model.
2. **impl**: InMemory + Pg location stores (delete refuses while items reference it) and
   asset stores; changeset 008 (par-value columns), 009 (`assets` table, bytea);
   audit actions `location.create/delete`, `asset.attach/delete`.
3. **server**: `/api/v1/locations` CRUD; `/api/v1/items/{id}/assets` upload (raw bytes +
   filename header), `/api/v1/assets/{id}` download/delete; par values ride the existing
   item JSON.
4. **webapp**: locations page (list/create/delete); item edit gains location dropdown and
   min/max on-hand; items list flags below-min items; item detail gains an assets section
   (inline image/audio rendering, upload, delete) proxied through the webapp session.

## Sixth milestone (Phase 4: QR and labels)

1. **server**: zxing QR generation — `GET /api/v1/items/{id}/qr.png` encodes
   `{inventory.qr.base-url}/i/{id}`; `LabelPrinter` interface in api with a logging
   default implementation; `POST /api/v1/items/{id}/print-label` dispatches to it and
   audits `label.print`. Real printer vendors remain an open unknown.
2. **webapp**: `GET /i/{id}` deep link (scan target) redirecting into the item page;
   item detail shows the QR code and a print-label button.

## Label pipeline and printer testing

*Added 2026-08-06. The label path decomposes into four stages; the first three are fully
testable on macOS without printer hardware, because JVM-mode AWT works completely there —
the native/Linux constraint applies only to the shipped binary, never to development.*

1. **Compose** — item fields + QR + text (+ future logos) → label bitmap via Java2D.
   Tested with golden-file snapshots: render, compare against approved reference images;
   plain JVM unit tests in inventory-server.
2. **Encode** — bitmap → printer command language. Label printers speak text-ish
   protocols (ZPL for Zebra — the de-facto reference — EPL, TSPL, Brother raster), which
   are strings/byte streams: unit tests assert the generated commands directly. During
   development, generated ZPL can be eyeballed with the Labelary renderer.
3. **Transport** — commands → device. The dominant transport is raw TCP port 9100
   (JetDirect). Tests run a *fake printer*: a trivial socket server capturing bytes,
   asserted like any other fixture. macOS also runs CUPS natively, so a local file-backed
   print queue covers IPP/queue-based printers for manual checks.
4. **Hardware** — the only stage requiring metal: a manual smoke checklist in the Phase 5
   runbook, deferred until the printer vendor (open unknown) is chosen. The vendor choice
   gates only stages 2 and 4's specifics — never the architecture, which stays behind the
   existing `LabelPrinter` interface.

## Verification

- `mvn clean verify` at the workspace root: all modules green.
- `quarkus dev` in `inventory-server`: `GET /q/openapi` serves the contract; full CRUD
  round-trip via curl with the dev token; an audit row exists for every mutation.
- Second milestone: `quarkus dev` in webapp + server; log in via the browser, browse
  from an item to a subitem and back via its container link, move an item between
  containers and see both container pages update; server log shows `item.move` audit.
- Liquibase: a fresh Postgres container reaches current schema from empty; rolling back
  the latest changeset succeeds (README's forward-and-possibly-backward migration goal).
- Phase 5 gate: `mvn verify -Dnative` produces a native executable that passes the same
  integration tests; container restarts (cold and warm) lose no committed data.

## Open unknowns (tracked, not blocking)

- iOS/Android app stack and timeline (README: "eventually").
- Label-printer protocols/vendors to support.
- Deployment target among swarm/nomad/k8s (manifests kept portable until chosen).
- Asset storage backend (object store vs. Postgres) — decided in Phase 3.
