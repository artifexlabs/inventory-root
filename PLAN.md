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
| Web tier split | **`inventory-web-api` (API) + new `inventory-webapp` (UI)** *(added 2026-08-07)* | The original `inventory-webapp` module was renamed to `inventory-web-api` (GitHub repo, directory, and Maven artifact). A new `inventory-webapp` module (fresh repo, Quarkus/Maven skeleton building and testing like its siblings) receives the actual web UI in Phase 5, leaving `inventory-web-api` as the pure browser-facing API tier (sessions, login/OIDC exchange, JSON the UI consumes). Rationale: with the UI isolated behind a JSON contract, it can be restyled or wholesale replaced later — different framework, even a different language — without touching any API tier. |
| Web UI direction | **Island architecture: Qute shell + Svelte islands; thick web-api, thin frontend** *(decided 2026-08-07)* | Planned interactions (photo annotation — draw boxes on a space picture and turn them into items/containers — and more to come) are real client-side interactivity, but the app's majority remains server-rendered CRUD. So: keep the Qute/Pico shell; mount self-contained **Svelte** components compiled as custom elements exactly where interactivity is needed (`quarkus-web-bundler` keeps the npm build inside Maven, TypeScript for island code). If the app ever tips majority-interactive, islands migrate into **SvelteKit** — a gradient, not a rewrite cliff. (React islands were the considered alternative; rejected for now: heavier baseline, ecosystem weight not yet needed.) Complementary principle: **web-api thickens, frontend thins** — aggregation, pagination, derived display fields live in web-api (serving web and future mobile once); business rules stay in inventory-server; the webapp renders and holds the session. Boundary test: an `if` that changes what is *allowed* belongs in inventory-server; one that changes what is *shown* may live in web-api; the webapp only renders. |
| Label printer hardware | **Brother PT-P750W first** *(decided 2026-08-08; printer in hand)* | Wi-Fi with a built-in print server accepting **raw TCP 9100** — exactly the transport stage 3 was designed around — and it speaks Brother's **documented** raster protocol (official Raster Command Reference; `ptouch-print` as OSS prior art), so the encode stage implements a spec instead of reverse-engineering. Constraints accepted: TZe tape ≤ 24 mm at 180 dpi (~128-dot head) → continuous strips, QR ≤ ~18 mm with text lengthwise; first physical gate is phone-scannability of an 18 mm QR. The DYMO MobileLabeler (1982171) was evaluated and rejected for system integration: Bluetooth-only, proprietary/undocumented app-oriented protocol, and Bluetooth-into-container plumbing — it stays a manual label maker. **Second target (ordered 2026-08-09, arriving ~2026-08-13): Zebra GK420t** — thermal transfer (temperature-stable labels; polypropylene + wax/resin ribbon is the recommended media), 203 dpi, 4-inch die-cut stock, ZPL — which turns the recorded ZPL reference encoder into real hardware. On arrival, verify which connectivity variant it is: Ethernet gives the standard TCP-9100 transport; a USB-only unit needs a transport decision before integration. Everything stays behind `LabelPrinter`, so none of this forecloses other vendors. |
| Federated identity | **`user_identities(provider, subject)` join table; email demoted to profile data** *(decided 2026-08-13, with Sign in with Apple)* | Today every lookup is email-keyed and `InventoryUser` even documents email as "the Google OIDC subject email". Apple breaks that: "Hide My Email" hands out per-app `@privaterelay.appleid.com` addresses, so email is neither stable nor matchable across providers. The stable key each provider guarantees is the OIDC `sub` claim, scoped to the issuer — hence a `(provider, subject) → user_id` join table, identity-first resolution at the exchange (subject match → email match linking a new provider to an existing account → invited/auto provisioning policy), and Google logins start recording their `sub` too. `TokenService`, sessions, and admin stay provider-agnostic — nothing downstream of the exchange changes. |
| Formal releases | **Tag-driven CI releases; container images to private GHCR under the `inventory-root` namespace; mobile releases on separate tracks** *(decided 2026-08-14)* | Images are the target artifact for all non-mobile code — the apps embed the libraries, every consumer builds from source in the one reactor, so no Maven artifact repository is needed (revisit only if an external build ever consumes the jars). One version for the whole platform: a `vX.Y.Z` tag on the superproject releases everything together, sidestepping the multi-repo ordering problem that breaks `maven-release-plugin` (one SCM per reactor is assumed; we have seven). All images publish to **private GHCR under `ghcr.io/<owner>/inventory-root/<module>`** — grouped in one place, each keeping its own name. `develop` stays SNAPSHOT forever; release versions exist only at tags (CI-friendly `${revision}` + flatten). iOS (and later Android) release through store channels (TestFlight/App Store, Play Console) with their own versioning and signing — deliberately not part of the image pipeline. |
| Label/QR rendering in native | **`quarkus-awt`** *(revised 2026-08-06; supersedes the pure-PNG-encoder decision of 2026-08-05)* | Labels will compose text and possibly other images alongside the QR — that is real Java2D (`Graphics2D`, fonts), which a bare PNG encoder cannot do. quarkus-awt makes AWT work in native images with Quarkus maintaining the metadata. Costs accepted: native images are Linux-only (the deploy target is Linux containers anyway) and the container image must carry fonts + fontconfig. macOS development is unaffected — headless AWT works fully on the JVM, so all dev and tests run on the Mac; native verification happens by container-building and container-running. If labels ever turn out to be QR-only after all, the pure-JDK 1-bit PNG encoder over zxing's `BitMatrix` remains the recorded simplification option. |

## Decision needed SOON — Locations vs. unified containment *(raised 2026-08-14; decide before inventory is widespread)*

**The question**: keep `Location` as a separate concept, or drop it in favor of
containers-with-coordinates — one physical hierarchy where a "location" is just a
root container (house → room → shelf → box), and an item's effective coordinates
are inherited from the nearest ancestor container that has a pin.

**Why it must be decided early**: the migration converts every `Location` row into
a root container item and every `items.location_id` reference into a containment
edge, and it ripples across the schema, `/api/v1/locations`, the bus actions, the
web-app locations page, the iOS app, and the `locationName` view field. All of
that cost scales with how much inventory data and how many clients exist —
cheap now, expensive after the system is widespread. **Deferring the decision is
choosing the status quo at compounding interest.**

**What argues for the collapse**: physically there IS only one hierarchy — places
are big immovable containers. The current split lets containment and `locationId`
drift (a tote marked "garage" gets boxed into one marked "attic"; nothing
reconciles them), while coordinate inheritance handles moves better than today:
move the tote to the cabin and its contents come along; under the current model
the contents keep stale locationIds.

**What argues against / blockers**:
1. **Multi-membership is the real blocker**: `addToContainer` permits an item in
   several containers at once (only `moveToContainer` is exclusive). Inherited
   coordinates are ambiguous in a DAG — the collapse REQUIRES committing to
   single-parent placement (a tree). That is a semantic decision, not a refactor.
2. The audit/event vocabulary is a public contract (VERTICLES.md):
   `location.create/delete` need a deprecation window, not deletion.
3. Client surface: REST, bus, web UI, iOS, views, Liquibase schema all touch.

**Recommended shape if adopted** (staged): (a) commit to single-container
placement — `moveToContainer` semantics become the only write path; (b) add
optional `LatLong` to `Item`; (c) migrate each `Location` to a root container
item of `type=location`, `location_id` references → containment edges;
(d) keep `/api/v1/locations` as a compatibility view over `type=location` items
while web/iOS migrate; (e) emit both audit vocabularies through the deprecation
window. Coordinates resolve as "nearest ancestor with a pin."

**Cheap interim if deferred**: keep `Location`, but derive an item's effective
location by walking up the containment chain (containment wins over the item's
own `locationId`) — kills the drift problem with no schema or client changes.

**What Locations could grow into if kept instead** (the other fork): hierarchy
(house → room → shelf), place metadata (address, access notes, a room photo
annotated with the existing region machinery), location-scoped reports and
audit filters (insurance/valuation per site), per-site par values, GPS
auto-suggest in the mobile app, a QR at the door opening "what's in this room",
and location-scoped roles once multi-user arrives. Choosing to keep Locations
should mean investing in some of this, not letting them stay a bare name+pin.

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
| [inventory-server/](inventory-server/) | **PARKED 2026-08-14** (HTTP consolidation, [VERTICLES.md](VERTICLES.md)): its REST surface, backend wiring, and OpenAPI moved into `inventory-web-api`; the module is out of the reactor and compose. History and code remain in its repo, tagged `before-remove-inventory-server`. |
| [inventory-web-api/](inventory-web-api/) *(formerly `inventory-webapp`; artifact renamed 2026-08-07; absorbed inventory-server 2026-08-14)* | Quarkus app: **the single HTTP tier** — domain REST resources over `InventorySystem` and friends, OpenAPI, token auth, health probes, plus the `/api/v1/views/*` aggregates (page-shaped payloads, pagination, derived display fields) now composed in-process from the domain beans. Serves web and mobile clients. |
| [inventory-mobile-apps/](inventory-mobile-apps/) *(new 2026-08-09; org `lawfulevilorg`, unlike the `mykelalvis` server-side repos)* | Umbrella submodule holding the per-platform mobile apps as nested submodules: `inventory-ios-app` (SwiftUI universal, compiling skeleton) and `inventory-android-app` (**Kotlin + Jetpack Compose** — stack decided 2026-08-09 with its compiling skeleton). Not Maven; not in the aggregator — built via `just mobile-build` (= `ios-build` + `android-build`). |
| [inventory-web-app/](inventory-web-app/) *(new 2026-08-07; directory renamed from `inventory-webapp` 2026-08-09 to match the GitHub repo)* | Quarkus app: the web UI (extracted from `inventory-web-api` in Phase 5) — Qute pages over Pico.css + design tokens, session cookie + OIDC dance, calling web-api only. Gains Svelte islands (Phase 8) for interactive surfaces. |

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

### Phase 5 — Web UI extraction *(seventh milestone — detail below; executed 2026-08-07)*
- Move all actual web-UI work (pages, templates, static assets, the session cookie the
  browser sees) from `inventory-web-api` into the new `inventory-webapp` module;
  `inventory-web-api` becomes the pure browser-facing API tier.
- `inventory-webapp` stays a Maven/Quarkus build identical to the siblings so the
  standing test flow keeps working. Any transition to a different web framework — or a
  different language entirely — comes **after the native/deploy phase (Phase 7)**, and
  is enabled (not required) by this extraction.

### Phase 6 — API shaping: web-api becomes an aggregating BFF *(eighth milestone — detail below; swapped ahead of native/deploy 2026-08-07)*
- Thicken `inventory-web-api` from transparent gateway to aggregating BFF: page-shaped
  aggregate endpoints, pagination/filter/search for listings, derived display fields
  (e.g. `belowMin`) computed once for every client. The webapp thins to rendering.
- Per the web-UI-direction decision: shaping lives here, business rules stay in
  inventory-server, and everything added serves the future mobile apps identically.

### Phase 7 — Native and deploy *(was Phase 5, then 6; swapped 2026-08-07)* — EXECUTED 2026-08-07

*As built: all three apps compile to native and run as containers; the full smoke flow
(login, CRUD, `qr.png` + zxing decode of the deep link, `print-label` 204, BFF view,
browser login/items/detail/deep-link through the native webapp) passes against the
compose stack, and warm + cold restart drills lose no data. Native fixes found on the
way: `Ulid`'s static `SecureRandom` marked initialize-at-run-time (shipped as
`META-INF/native-image` metadata in inventory-impl); `InventoryBackendProducer` reads
config lazily via `ConfigProvider` because native static-init froze field-injected
values at build-time defaults (`storage=memory` inside a pg container); runtime images
must be UBI9 to match the Mandrel builder's glibc; the server image ships the
`libawt*.so` set the AWT native build emits, with `-Djava.library.path=/work`, plus
fontconfig + dejavu fonts. Deployment is `docker-compose.yml` at the root (portable
reference; swarm/nomad/k8s still open) with a Liquibase-CLI `migrate` service — the
day-2 migration path — running before the server. Clustered event bus deliberately NOT
configured: no inter-service event-bus traffic exists (services speak HTTP). Runbook:
[RUNBOOK.md](RUNBOOK.md). Hardware label-printer smoke remains deferred on the vendor
unknown.*
- **AWT-in-native via `quarkus-awt`** (per the label/QR rendering decision above): add
  the extension to inventory-server; container image gains fonts + fontconfig (e.g.
  dejavu) so text renders in native; macOS flow is
  `mvn verify -Dnative -Dquarkus.native.container-build=true`, then run the built
  container and drive the standing smoke flow (login, CRUD, `qr.png`, `print-label`).
  Gate: the `QrAndLabelTest` decode round-trip stays green in JVM tests, and the same
  check is repeated with curl+zxing against the running native container.
- Native-image builds for server, web-api, and webapp; container images; compose/nomad/k8s
  manifests; clustered event-bus configuration; cold/warm restart drills; backup/restore
  and migration runbooks (day-2).

### Phase 8 — Spatial annotation: photo → boxes → items *(ninth milestone — detail below; EXECUTED 2026-08-09)*
- Upload a picture of a space, draw boxes on it, and turn each box into an
  item/container. Region model and transactional create-from-region land in the API
  tiers first; the first Svelte island (the annotator) arrives with its build
  toolchain; everything else stays server-rendered.
- **Multi-box annotation flow** *(added 2026-08-09)*: drawing and data entry are
  separate steps — draw MANY boxes on the photo in one sitting, then set each box's
  data individually (name, type, and whether it becomes a plain item or a containing
  item that can hold others). Boxes without data yet persist as unlinked regions.
- **Location from photo metadata** *(added 2026-08-09)*: if the uploaded picture
  carries GPS EXIF data, extract the lat/long server-side at asset upload and offer it
  as the space's `Location` (match an existing location within tolerance, else
  prefill a create form) — suggested, never silently applied. Best-effort by nature:
  many phones and share paths strip EXIF.
- **Device GPS from the mobile apps** *(added 2026-08-09)*: the mobile clients
  (Phase 12+) don't depend on EXIF surviving — the app reads the phone's GPS at
  capture time and sends lat/long explicitly with the asset upload, feeding the SAME
  location-suggestion pipeline. Explicit coordinates win over EXIF when both exist.

### Phase 9 — Label hardware: Brother PT-P750W *(tenth milestone — detail below)*
- Independent of Phase 8 and may run before or alongside it — the P750W is physically
  available as of 2026-08-09, and every stage except the final physical smoke tests
  without hardware. The Zebra GK420t (second target, ZPL, ~2026-08-13) extends this
  milestone with a `ZplEncoder` + `ZebraPrinter` once it arrives — same compose stage,
  same transport if it is the Ethernet variant.
- Realize label-pipeline stages 1–3 for real: Java2D compose → Brother raster encode →
  TCP 9100 transport, wired as a `LabelPrinter` implementation selected by config;
  finish with the physical smoke (print a label, phone-scan the QR into `/i/{id}`).

### Phase 10 — CI readiness *(no ordinal milestone; devcontainer landed 2026-08-08)*
- **One container, two jobs**: [.devcontainer/](.devcontainer/) builds an image that is
  both the local Dev Containers environment and the base image for GitHub Actions
  container jobs. Ubuntu 22.04 + Temurin JDK 21 + Maven 3.9.16 (the parent enforces
  ≥ 3.9.16) + git + docker CLI/compose/buildx, plus the JDK-21 Maven toolchains.xml
  the build demands (for root — Actions — and vscode — devcontainer). Docker itself is
  not inside: both uses talk to the host daemon (locally via the
  docker-outside-of-docker feature, in CI via the runner's mounted socket).
  *Verified 2026-08-08: image builds locally and `mvn test` of inventory-api passes
  inside it.*
- **Workflows** in [.github/workflows/](.github/workflows/):
  `devcontainer-image.yml` publishes the image to
  `ghcr.io/mykelalvis/inventory-devcontainer:latest` on .devcontainer changes;
  `ci.yml` runs `mvn verify` for all modules inside that image (docker socket mounted
  for Testcontainers/Dev Services, ryuk disabled). Submodule checkout rewrites the SSH
  URLs in .gitmodules to HTTPS before checkout so the token flows.
- **First-run notes**: the image workflow must run once before ci.yml can pull the
  image (chicken-and-egg on the very first push); observing both workflows green on
  GitHub is the remaining gate and happens at the next authorized push. Mobile CI
  (macOS runners for iOS) is explicitly out of scope here — noted for the mobile
  milestone.
- **CI dependency — RESOLVED 2026-08-13**: `ibparent` 112 was released to Maven
  Central; `inventory-parent` now parents off the released `112` (was
  `112-SNAPSHOT`), so CI resolves the whole parent chain remotely. The full local
  `mvn verify` and CI both pass against it.
- **CI blocker #2 — private-submodule checkout, RESOLVED 2026-08-13**: with the
  parent resolvable, CI surfaced the next failure: all `inventory-*` repos are
  private, and the workflow's `GITHUB_TOKEN` only reaches `inventory-root`, so
  every submodule clone got "repository not found". Fix: `ci.yml` passes
  `token: ${{ secrets.SUBMODULE_TOKEN || github.token }}` to `actions/checkout`;
  `SUBMODULE_TOKEN` is a fine-grained PAT (contents:read on the `inventory-*`
  repos) stored as a repo secret on `inventory-root`.
- **Phase 10 gate PASSED 2026-08-13**: first fully green `ci.yml` run
  (31711062159, 5m06s) — GHCR devcontainer image pull, private-submodule checkout,
  and the full six-module `mvn verify` with Testcontainers all work on GitHub.
  Publishing remains out of scope: CI stops at `verify`; no Maven artifacts are
  deployed anywhere.

### Task — Dependabot remediation: web-app npm island toolchain *(added 2026-08-13; EXECUTED 2026-08-13)*

**Outcome**: upgraded in one move to `svelte 5.56.9` / `vite 6.4.3` / `vitest 3.2.7` /
`@sveltejs/vite-plugin-svelte 5.1.1` (vite pinned to 6.x because frontend-maven-plugin
installs Node v20.18.1; vite 7 needs ≥ 20.19). The annotator island compiled unchanged
(Svelte 5 legacy syntax + `customElement` path), `npm audit` reports 0 vulnerabilities,
local and CI `mvn verify` green (run 31715299939), and **open Dependabot alerts dropped
21 → 0**. Remaining nicety, not a gate failure: an in-browser smoke of the annotator
island under Svelte 5 (the Quarkus page tests cover serving, not pointer interaction).

GitHub reports **21 open Dependabot alerts on `inventory-web-app` (2 critical, 1
high, 16 moderate, 2 low)** — all in the npm island toolchain under
[inventory-web-app/src/main/web/package.json](inventory-web-app/src/main/web/package.json)
(pinned: `svelte 4.2.19`, `vite 5.4.11`, `vitest 1.6.0`, `@sveltejs/vite-plugin-svelte
3.1.2`; `esbuild` is transitive via vite). Everything here is build/dev tooling except
`svelte`, whose compiler output ships in the islands. Full list:
`gh api repos/mykelalvis/inventory-web-app/dependabot/alerts`.

- **Criticals (vitest)**: GHSA-9crc-q9x8-hgqq (RCE while the vitest API server
  listens; fixed 1.6.1) and GHSA-5xrq-8626-4rwp (arbitrary file read/execute via
  Vitest UI server; fixed 3.2.6). Clearing both means **vitest ≥ 3.2.6** — a
  two-major jump from 1.6.0.
- **High (vite)**: GHSA-fx2h-pf6j-xcff (`server.fs.deny` bypass; affects ≤ 6.4.2,
  fixed only in 6.4.3) — so clearing the high requires **vite ≥ 6.4.3**, not just
  the 5.4.21 tail of the twelve 5.x mediums/lows.
- **Moderates (svelte ×6)**: SSR XSS family; fixes land in 5.51.5–5.55.7 → requires
  **svelte ≥ 5.55.7**, i.e. the Svelte 4 → 5 major migration.
- **Moderate (esbuild)**: GHSA-67mh-4wv8-2f99 (dev server responds to any website;
  fixed 0.25.0) — resolves transitively once vite ≥ 6.

**Task (one coherent toolchain upgrade, not per-alert patches):** bump to
`svelte ≥ 5.55.7`, `vite ≥ 6.4.3`, `vitest ≥ 3.2.6`, and the matching
`@sveltejs/vite-plugin-svelte` major (Svelte-5/Vite-6 compatible line). Svelte 4→5
is the real work: verify the islands still compile as custom elements
(`customElement` compiler path), the annotator island behaves identically, and the
8 vitest tests pass. Gate: `mvn -B -ntp verify` green locally and in CI, plus a
manual smoke of the space-annotator page; then confirm the Dependabot alert count
drops to zero. Risk containment: severities are dev-server/test-runner attack
surface except the svelte SSR XSS items, and the islands are client-compiled (no
Svelte SSR in this app) — which is why this is scheduled as a deliberate task
rather than an emergency patch.

### Phase 11 — Mobile developer readiness *(was Phase 10; renumbered 2026-08-08; checklist in [MOBILE-READINESS.md](MOBILE-READINESS.md); no ordinal milestone)*
- Every credential and tool needed to start iOS/Android development, gathered BEFORE
  the mobile work begins: Apple Developer Program enrollment, Google Play Console
  account (identity verification has multi-day lead time — start early), full Xcode +
  simulator, Android Studio + SDK + device, upload keystore. Mostly human actions;
  machine-verifiable items were checked on the dev Mac 2026-08-08 (JDK 21 and Apple
  CLT present; Xcode, Android SDK, and Node absent) and each carries its re-verify
  command in the checklist.
- Order-independent: run whenever convenient — account verifications benefit from
  starting early. Done = checklist green except its explicitly deferred items.
- Deliberately does NOT choose the mobile stack (still an open unknown); the
  deep-link wiring (universal links / app links) is listed but deferred on a public
  HTTPS domain.

### Phase 12 — Create initial mobile app: iOS universal *(eleventh milestone — detail below; added 2026-08-09)*
- A native **Swift/SwiftUI universal app** (iPhone + iPad, one target) at
  [inventory-mobile-apps/inventory-ios-app/](inventory-mobile-apps/inventory-ios-app/),
  consuming only the `inventory-web-api` JSON surface — the same contract as the web
  UI. This resolves the iOS half of the mobile-stack unknown (Android decides at its
  own phase and need not match).
- **Not a Maven app**: built by `xcodebuild` through the [Justfile](Justfile) mobile
  recipes (`just ios-build` / `ios-test` / `ios-open`) — macOS-only by nature, so the
  recipes are `[macos]`-gated and never part of `mvn verify`, the compose stack, or
  the Linux CI lanes (iOS CI needs macOS runners; noted since Phase 10).
- Prerequisites: the Phase 11 checklist's Xcode + simulator items (Apple Developer
  Program only when device installs/TestFlight start); a reachable web-api.

### Phase 13 — Federated identity: Sign in with Apple *(twelfth milestone — detail below; added 2026-08-13)*
- **Sign in with Apple everywhere Google OIDC works today**: a second button on the
  webapp login page, a second named OIDC tenant (`quarkus.oidc.apple.*`, Quarkus's
  built-in `provider=apple` preset), and a provider-aware exchange so the server
  keys identity on `(provider, subject)` instead of email (see the federated-identity
  decision row).
- Apple is also a **future iOS requirement**: App Store review requires Sign in with
  Apple in any app offering other third-party logins, so Phase 12's login screen
  inherits this work (native `ASAuthorizationController` → id-token exchange at
  web-api — wired at Phase 12, not here).
- Built disabled-by-default like Google (`OidcDisabledTest` pattern): all wiring and
  tests run without Apple credentials; flipping it on needs an Apple Developer
  Program account (Services ID = OIDC client-id, ES256 signing key, team ID) and an
  HTTPS redirect URL (Apple refuses plain-http callbacks — real logins need a
  TLS-fronted deployment or a tunnel even in dev).

### Phase 14 — Formal releases: tag-driven images to private GHCR *(thirteenth milestone — detail below; added 2026-08-14)*
- One `vX.Y.Z` tag on the superproject releases the whole platform: CI builds the
  reactor at that version, publishes native images for `inventory-web-api`,
  `inventory-web-app`, and `inventory-exporter` to **private GHCR under
  `ghcr.io/<owner>/inventory-root/<module>:<version>`**, and mirrors the tag into
  every submodule repo. No Maven artifact publishing — images are the deliverable
  (see the decision row).
- **Mobile is explicitly separate.** iOS releases via the store track (Xcode archive
  → TestFlight → App Store; `MARKETING_VERSION`; signing; needs the Phase 11 Apple
  Developer account) and Android, when it exists, via its own (Play Console, signed
  AAB). Store review cycles, signing chains, and versioning have nothing in common
  with image publishing — forcing them into one pipeline would couple a `git tag`
  to human review timelines. Each gets its own phase when distribution starts.

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

## Seventh milestone (Phase 5: web UI extraction) — EXECUTED 2026-08-07

*Added 2026-08-07; executed the same day. As built (two deliberate deviations from the
original sketch, both recorded below):*

1. **`inventory-webapp`** — now the browser-facing UI app (port 8082): the Qute
   templates, `PageResource`, the session cookie + `SessionStore` + `UserLookup`,
   **and the Google OIDC dance (`OidcLoginResource`)** all moved here verbatim,
   package `org.lawfulevil.inventory.webapp` unchanged. *(Deviation 1: the original
   sketch kept the OIDC dance in web-api, but the dance is browser redirects that end
   in session-cookie creation — inseparable from the session tier without a cross-app
   handoff protocol. The exchange call itself still reaches inventory-server, through
   the gateway.)* The moved `HttpServerClient` now targets `inventory.web-api.url`
   (default `http://localhost:8081`); the browser talks only to the webapp, the webapp
   talks only to web-api, and the API token lives in the server-side session, never
   the browser.
2. **`inventory-web-api`** — now the pure web API tier: a single `ApiProxyResource`
   (new package `org.lawfulevil.inventory.webapi`) transparently forwards the whole
   `/api/v1/*` surface — method, path, query, body, Authorization / Content-Type /
   X-Exchange-Secret / X-Filename headers — to inventory-server, and serves no HTML
   (any non-`/api/v1` path is 404). *(Deviation 2: rather than re-implementing
   per-endpoint JSON resources, the tier is a transparent gateway — the stable public
   surface for the UI today and mobile apps later, with zero duplicated contract.)*
   Qute, OIDC, and the inventory-api dependency dropped from its pom.
3. **Tests moved with the code**: all seven page/session/OIDC test classes (plus
   `StubServerClient`) run unchanged in `inventory-webapp`; `inventory-web-api` gained
   `ApiProxyResourceTest` against a `StubBackend` echo server (a
   `QuarkusTestResourceLifecycleManager` on an ephemeral port) covering header/body/
   query forwarding, status pass-through (401/204), binary pass-through (`qr.png`),
   and the serves-no-HTML gate. Full aggregator `mvn verify`: green across all six
   modules.

The visual pass from the tech-path advice landed 2026-08-07 as its own commit: shared
`base.html` layout (Qute `{#include}`/`{#insert}`) with the nav in one place, design
tokens in `META-INF/resources/css/app.css` (accent, radius — rebrand by editing four
values), and vendored Pico.css v2.0.6 (fetched pinned from
`https://cdn.jsdelivr.net/npm/@picocss/pico@2.0.6/css/pico.min.css`) styling the
semantic markup classlessly. All seven pages extend the base; per-page inline styles
are gone. htmx remains future work — it is about interactivity, not visuals, and
nothing needs it yet.

### Web UI technology path (advice, recorded 2026-08-07)

- **Now (this milestone):** keep server-rendered Qute — the move is then a relocation,
  not a rewrite. Immediately after the move, take the cheap visual win:
  - One base layout template all pages extend (exists in embryo today).
  - **Design tokens as CSS custom properties** (colors, spacing, radii, fonts) in one
    stylesheet — restyling later = editing token values, not templates.
  - **Pico.css v2** as the styling layer: classless, ~10 KB, themes via those same CSS
    variables, styles semantic HTML directly — the existing plain templates get modern
    visuals with near-zero markup changes. (Step-up option if component richness is
    needed: Bootstrap 5.3 via `quarkus-web-bundler`; skip Tailwind for now — it drags
    in a node build step for little gain at this scale.)
  - **htmx** for interactivity (inline edits, live search, move-item without full
    reload): attribute-driven, no build step, no framework lock-in, plays naturally
    with server-rendered Qute fragments.
- **Later (after the native/deploy phase):** because the UI is one isolated module consuming only the
  `inventory-web-api` JSON contract, "transition to a new framework, potentially a
  different language" = replace `inventory-webapp` wholesale (SvelteKit, Next.js,
  anything) with zero changes to the API tiers; publishing the web-api OpenAPI document
  gives typed client generation in any language. Until that day, Qute + tokens + Pico +
  htmx keeps the UI modern-looking, easily styleable, and cheap to maintain.

**Superseded 2026-08-07** — the "Later" paragraph above is resolved by the
**Web UI direction** decision in the locked table: planned interactions (photo
annotation among them) settle the question in favor of an island architecture — Qute
shell + Svelte islands as custom elements (Phase 8 brings the first), SvelteKit only
if the app ever tips majority-interactive, and a thick web-api / thin frontend split
(Phase 6). The wholesale-replacement escape hatch remains real but is no longer the
expected path.

## Eighth milestone (Phase 6: aggregating BFF) — EXECUTED 2026-08-07

*Added and executed 2026-08-07. Motivation: the item detail page made six sequential
API calls; the items list fetched every item on every view; `belowMin` was computed in
the UI tier where mobile apps cannot reuse it. As built (one deviation, noted below):*

1. **`inventory-web-api`** — `ItemViewsResource` (read models) beside the proxy:
   - `GET /api/v1/views/items/{id}/detail` — one page-shaped payload: item, children,
     containers, candidates (id+name, self excluded), recent history (20), locations,
     assets, derived `locationName`. Collapses the detail page's six calls into one.
   - `GET /api/v1/views/items?query=&page=&size=` — paginated (default 25), filtered
     across name/displayName/type (case-insensitive), `belowMin` derived per row.
   - *(Deviation: views live under `/api/v1/views/*` instead of shadowing
     `/api/v1/items` — JAX-RS root-resource matching does not backtrack, so a literal
     `/api/v1/items` resource would swallow every `/api/v1/items/*` subpath and 404 or
     405 what it doesn't re-declare. A separate read-model namespace is also honest
     BFF design.)*
   - Aggregates are composed from the same inventory-server calls the proxy forwards
     (Authorization passed through; 401s propagate; optional sections degrade to empty
     lists; required calls failing → 502). Note for later scale: inventory-server still
     returns the full item list to this tier — push pagination down into the server
     when item count demands it.
2. **`inventory-webapp`** — `ServerClient` gained `itemsView(...)`/`itemDetail(...)`
   and lost the now-unneeded read methods (`items`, `containersOf`, `auditFor`,
   `assetsFor`); `PageResource` renders only — zero aggregation or derivation remains.
   Items page gained a search box and Previous/Next pagination (plain forms/links, no
   island).
3. **Tests**: `ItemViewsResourceTest` in web-api against `StubBackend` (now serving
   canned inventory-server JSON: filter, pagination, belowMin, full aggregate, 404,
   401); `AggregateViewsTest` in webapp asserts the gate — the detail page renders
   from exactly ONE view call (stub counter) — plus search behavior. Full aggregator
   `mvn verify` green across all six modules.

## Phase 7 (native and deploy) — no separate milestone section

*Phase 7 has no ordinal milestone of its own: its implementable detail and its as-built
record (executed 2026-08-07) live directly in the roadmap entry above, and its day-2
procedures live in [RUNBOOK.md](RUNBOOK.md). Listed here only so the milestone sections
read continuously — the phase sequence is 6 (eighth milestone) → 7 (roadmap only) → 8
(ninth milestone).*

## Ninth milestone (Phase 8: spatial annotation) — EXECUTED 2026-08-09

*Added 2026-08-07. Photo of a space → drawn boxes → items/containers. API-first: the
region model is valuable even with a crude UI, and the iOS/Android apps reuse it
wholesale (photographing a shelf is the most phone-shaped feature in the plan).*

***As built (2026-08-09)*** — *everything below landed as specified, with these
recorded deviations/refinements:*

- *Region ops live on a dedicated `RegionSystem` interface (not spread across the
  asset/inventory interfaces): promotion spans both stores, and one interface keeps
  the transaction in one place. `InMemoryRegionSystem` + `PgRegionSystem`; the pg
  promotion (item + containment + region link + item.create/item.contain/
  item.create-from-region audit rows) is ONE transaction.*
- *Draw-then-describe is API-real: `POST /assets/{id}/regions` persists a BARE box;
  `POST /regions/{id}/make-item` describes it later (404 once linked); the one-shot
  `POST /assets/{id}/regions/make-item` also exists for API/mobile callers.
  `DELETE /regions/{id}`; deleting an ITEM leaves its boxes bare (FK SET NULL);
  deleting the asset removes them (CASCADE). Changesets 010 (asset_regions) + 011
  (assets.latitude/longitude).*
- *EXIF: the minimal dependency-free GPS parser (the plan's sanctioned fallback —
  metadata-extractor passed over to keep native reflection-free). JPEG APP1 only,
  best-effort by design; explicit `?lat=&long=` upload params win over EXIF; both
  land on `AssetInfo.coordinates` (suggestion-only, per the Phase 8 addenda).*
- ***Island toolchain deviation**: `frontend-maven-plugin` (pinned Node v20.18.1) +
  Vite + Svelte 4, NOT quarkus-web-bundler — the bundler has no Svelte compilation
  path. The property that mattered is preserved: `mvn verify` is still the one
  command (Node auto-downloaded, npm install + vite build in generate-resources,
  vitest in test), and the built island ships as a static file in the app jar
  (`/islands/space-annotator.js`, ~28 KB, no runtime CDN). Sources in
  `inventory-web-app/src/main/web/` with committed package-lock.*
- *`<space-annotator>` (shadow-DOM custom element, attrs asset-id/item-id) renders
  every image asset on the item page: SVG overlay, pointer drag → immediate bare-box
  save, click → per-box describe form (name, type, "containing item" checkbox →
  type=container), linked boxes green with a link to their item; unfilled boxes
  persist across sessions. Session-cookie JSON endpoints on the webapp
  (`RegionApiResource`) forward through `ServerClient`; islands get 401s, not login
  redirects. Geometry is pure TS (`annotator-core.ts`) under vitest.*
- *Tests: impl EXIF unit tests (synthetic GPS JPEGs); server memory-mode
  `RegionsApiTest` (flow, audit, EXIF-vs-explicit) + pg-mode transactional region
  test in `PgModeApiTest`; webapp `SpaceAnnotatorPagesTest` (island mounts for image
  assets, bundle served, JSON surface through the session); 8 vitest geometry tests.
  Full `just verify`: 161 JVM tests green. (Side find: `just verify` used to leak
  the .env OIDC exchange secret into server tests, breaking
  OidcExchangeDisabledTest — the recipe now runs Maven with those unset.)*
- *Remaining human gate: the interactive drag-a-box-in-a-browser pass in
  `quarkus dev` — the automated page/JSON tests cover everything up to the pointer
  events.*

1. **`inventory-api`** — `AssetRegion` (id, assetId, normalized rect x/y/w/h in 0–1 so
   coordinates survive any display size, optional linked itemId, label); region
   operations on the asset/inventory interfaces: list/create/delete regions for an
   asset, and `createItemFromRegion(assetId, rect, name, type, containerId)` — create
   item + contain it + link the region, one transaction.
2. **`inventory-impl`** — changeset 010 (`asset_regions` table + rollback); InMemory +
   Pg implementations; audit actions `region.create`, `region.delete`,
   `item.create-from-region`.
   - **EXIF location extraction** *(added 2026-08-09)*: at asset upload, parse image
     metadata for GPS coordinates (library choice at implementation — e.g.
     `com.drewnoakes:metadata-extractor`; verify native-image friendliness, else a
     minimal EXIF GPS-tag parser). If present, surface lat/long on the `AssetInfo`
     so the tiers above can suggest a `Location`: match an existing one within
     tolerance or prefill location-create. Suggested, never silently applied;
     best-effort (EXIF is often stripped). No new tables — locations remain the
     existing first-class model.
   - **Explicit coordinates on upload** *(added 2026-08-09)*: the asset-upload
     operation accepts optional lat/long parameters so clients that KNOW the
     location — the mobile apps reading the phone's GPS at capture time — can pass
     it directly instead of hoping EXIF survives. Explicit coordinates take
     precedence over EXIF; both routes converge on the same `AssetInfo` fields and
     suggestion logic downstream.
3. **`inventory-server`** — `GET/POST /api/v1/assets/{id}/regions`,
   `DELETE /api/v1/regions/{id}`, `POST /api/v1/assets/{id}/regions/make-item`;
   rides through the web-api proxy untouched.
4. **`inventory-webapp`** — island toolchain + the annotator:
   - `quarkus-web-bundler` brings the npm build into Maven (`mvn verify` stays the one
     command); **Svelte + TypeScript**, each island compiled as a custom element.
   - First island `<space-annotator asset-id="...">` mounted from the item-detail
     template on image assets: `<img>` + SVG overlay, pointer events for
     draw/select/resize, a small form per box (name, type) posting create-from-region
     through the session. A few hundred lines of TS; no canvas library unless
     pan/zoom/rotate is later demanded (then Konva).
   - **Draw-then-describe** *(added 2026-08-09)*: the island supports drawing
     MULTIPLE boxes before any data entry — each drawn box saves immediately as a
     bare `AssetRegion` (no linked item), and selecting a box opens its form to set
     the data individually: name, type, and item-vs-**containing item** (container
     flag → the created item can itself hold others, nested under the space's
     container). Unfilled boxes persist across sessions as unlinked regions, so a
     photo can be fully boxed in one pass and described over several.
5. **Tests**: region CRUD + transactional create-from-region in impl (both backends)
   and server (one audit row, containment correct, region linked); webapp page test
   asserts the island element + its data attributes render for image assets. Island
   internals get vitest coverage inside the bundler build. Gate: full flow in
   `quarkus dev` — upload photo, draw box, name it, see the new item contained in the
   space's container with the region linked; aggregator green.

## Tenth milestone (Phase 9: Brother PT-P750W label printing) — stages 1–3 EXECUTED 2026-08-09; step 5 hardware smoke PASSED 2026-08-09

*Added 2026-08-08; stages 1–3 built and tested 2026-08-09 exactly as specified below
(one refinement: the golden label PNG is generated INSIDE the devcontainer so it pins
the Linux/DejaVu rendering production uses; the exact-pixel comparison runs on Linux
and platform-neutral invariants run everywhere).*

***Step 5 hardware smoke (2026-08-09)***: *P750W on the LAN at 10.0.1.130 (recorded
in the gitignored `.env`; TCP 9100 verified open), server run with
`inventory.printer=brother-p750w`, `just print-label` → the printer PHYSICALLY
PRINTED (414 raster lines, 24 mm tape) — the raster constants are hardware-confirmed.
The first print exposed a real bug the log printer could never show: the printer's
future completes on a ForkJoinPool thread, where the request-scoped `CurrentUser`
proxy is dead — the audit step threw `ContextNotActiveException` and the endpoint
500'd AFTER printing. Fixed by capturing the principal on the request thread before
dispatch; regression-locked by `BrotherPrinterModeTest` (dedicated `@TestProfile`
running the REAL `BrotherPTouchPrinter` against `FakeRasterPrinterResource`, a local
TCP sink that asserts the invalidate/ESC@ preamble and 0x1A terminator). Compose now
passes `INVENTORY_PRINTER*` env through to the server (defaults keep `log`).*

***Phone-scan gate PASSED (2026-08-09)***: *both printed labels scanned reliably on
an iPhone 15 Pro and were visually identical — the ~18 mm QR from 24 mm tape needs
no composer iteration. The Brother P750W path is DONE end to end: compose → encode →
TCP 9100 → hardware → phone scan.*

***Steps 3–4 COMPLETED (2026-08-09, same day, later)***: *the native
`inventory-server` image was rebuilt with the label pipeline (finding: ibparent-root
hard-pins `<skipTests>false</skipTests>` in surefire, so `-DskipTests` is silently
ignored — the Justfile's native flags now use `-Dmaven.test.skip=true`). Compose
gained the `fake-printer` service (alpine nc TCP-9100 sink, profile-gated behind
`--profile fake-printer`, jobs captured to a volume), and `just smoke-fake-printer`
runs the whole thing: native stack up pointed at the sink → print-label → 204 →
captured job verified byte-for-byte (100-byte invalidate + ESC@ … 0x1A; 9384 bytes
observed). The full Phase 7 curl smoke also passes on the new image, and a bonus
check exercised Phase 8 against native+pg: asset upload with explicit `?lat&long`
(coordinates stored), bare region, make-item promotion, link readback — all green.
Steps 1–5 are now COMPLETE. Step 6 (Zebra GK420t) EXECUTED 2026-08-14 — see its
caveats note; the milestone is functionally closed.*

1. **`inventory-impl`** — the pipeline stages as plain classes (CDI-light, like the
   other impl code):
   - `LabelComposer` (stage 1): item name/id + QR `BitMatrix` → 1-bit label bitmap via
     Java2D, sized for the P750W head (height = 128 dots at 180 dpi for 24 mm TZe,
     parameterized for narrower tapes; width grows with content). Golden-file
     snapshot tests.
   - `BrotherRasterEncoder` (stage 2): 1-bit bitmap → Brother raster command bytes
     per the official Raster Command Reference (invalidate, initialize, mode/media
     switches, one raster line per column, print-and-feed). Unit tests assert exact
     command bytes for known bitmaps.
   - `Tcp9100Transport` (stage 3): bytes → host:port over a plain socket. Tested
     against the *fake printer* (an ephemeral-port capture server, same pattern as
     web-api's `StubBackend`).
   - `BrotherPTouchPrinter implements LabelPrinter` composing the three, plus config:
     `inventory.printer=log|brother-p750w` (default stays `log`),
     `inventory.printer.host`, `inventory.printer.port` (default 9100),
     `inventory.printer.tape-mm` (default 24).
2. **`inventory-server`** — the backend producer selects the `LabelPrinter` by
   `inventory.printer` (same switch pattern as `inventory.storage`); `print-label`
   endpoint and `label.print` audit are already in place and unchanged.
3. **Native**: compose/encode are pure Java2D + byte arrays (already covered by the
   quarkus-awt work); confirm the golden-file check passes identically in the native
   container (same curl smoke as Phase 7, now asserting real raster bytes reach the
   fake printer).
4. **Compose stack**: printer host/port arrive via environment; the fake printer can
   run as a compose service for end-to-end tests without hardware.
5. **Hardware smoke** (the only step needing the device, RUNBOOK checklist): point
   `inventory.printer.host` at the P750W on the LAN, `POST .../print-label`, and
   phone-scan the printed QR — it must resolve through `/i/{id}` to the item page.
   First physical gate: an ~18 mm QR from 24 mm tape scans reliably; if not, iterate
   module size/quiet zone in the composer before anything else.
6. **Zebra GK420t extension** — **EXECUTED 2026-08-14** (built the same day as the
   bench verification below; one hardware print through the full bus path returned
   204 with an attributed `label.print` audit row). Remaining caveats, deliberately
   open: (a) golden-file pinning of the two die-cut layouts is ink-region
   invariants only until the goldens are generated inside the devcontainer
   (Linux/DejaVu fonts, same `-Dlabel.golden.update=true` flow as the Brother
   layout); (b) the `standard` format has passed only the fake-printer path — no
   hardware print until standard stock is loaded (print discipline applies);
   (c) the `large` field set was finalized WITHOUT location name (the printer has
   no LocationSystem access; add it only if a location lookup ever moves into the
   labels worker). Original step text follows.
   `ZplEncoder` (stage 2, the
   reference dialect — `^GFA` graphic field from the same 1-bit bitmap, eyeballable
   via Labelary during development) and `inventory.printer=zebra-gk420t` wiring.
   Connectivity DECIDED 2026-08-12: **Ethernet initially** — reuses
   `Tcp9100Transport` unchanged (`inventory.printer.host`/`.port`, exactly like the
   Brother). A later switch to **USB as a captured "local" connection** (printer
   tethered to the serving host, off the LAN) stays open; when taken, it needs a
   transport decision — likely a `UsbTransport`/spool alternative behind the same
   stage-3 interface, with host-OS specifics (CUPS raw queue vs direct usb device)
   recorded then. Die-cut media sizing enters the composer as a second label
   geometry (width × height instead of fixed-height continuous tape).
   - **Hardware verified on the bench 2026-08-14** (probe + first print over raw
     TCP 9100 at 10.0.1.132): `~HI` answers `GK420t-200dpi,V61.17.17Z,8,2104KB` —
     ZPL II live, 203 dpi, Ethernet variant confirmed (so `Tcp9100Transport`
     carries it unchanged, connectivity question closed). Gap-sensed label pitch
     calibrates to **836 dots (4.12 in)** = the 4-in label plus its ~1/8-in die-cut
     gap, so the printable geometry stays 457×812 and `^LL` is deliberately
     omitted — gap sensing drives the feed on die-cut media. A hand-written
     `large`-layout ZPL test label printed clean (border box, mag-10 `^BQ` QR
     ≈1.8 in, name/id/fields). Noted: ZPL's `^BQ` magnification caps at 10, so a
     true 2-in QR comes from the `^GFA` bitmap path (where size is arbitrary) —
     which is the planned encoder anyway.
   - **PRINT DISCIPLINE** *(standing, 2026-08-14)*: label stock is consumed by
     every test. Once code is verified, printing happens ONLY on explicit
     instruction, or with prior notice that a change needs re-verification.
     Everything else uses golden files, the fake-printer sink, and ZPL
     inspection. (The Brother powers off after ~10 min idle — unreachable is
     normal, not broken.)
   - **Two named label formats** *(added 2026-08-12; media in hand/ordered)*:
     - `standard` — 2.25×1.25 in (457×254 dots @203 dpi): the Brother layout
       adapted — full-height QR (~1.1 in) left, name + id right. The default.
     - `large` — 2.25×4 in (457×812 dots): MORE information and a BIGGER code —
       a ~2 in QR centered up top (scans from across a room), then name (large),
       id (mono), and additional fields as space allows: type, location name,
       description (wrapped/truncated), and a printed-on date. Exact field set
       finalized at implementation against real items.
     - Selection: `inventory.printer.format` config sets the default;
       `POST .../print-label?format=large` overrides per print. The composer owns
       formats (pure Java2D layout fns); encoders stay format-agnostic (they just
       rasterize whatever bitmap arrives) — so `large` works on any future
       printer whose media fits it, and golden-file tests pin BOTH layouts.

## Eleventh milestone (Phase 12: initial iOS universal app)

*Added 2026-08-09. First mobile client; everything it needs from the backend already
exists behind `inventory-web-api`.*

*App v1 BUILT 2026-08-13 (`just ios-build` green, Xcode 26.3): Settings holds the
web-api base URL and email/password login (token in Keychain); the app opens on the
items list; item CRUD (create with container toggle, edit via full-JSON PUT
round-trip, swipe delete) plus print-label; in-app camera capture (photo library on
the simulator) uploads assets and opens a native annotator — drag normalized boxes
on the photo, describe each box, and the one-shot `regions/make-item` call mints it
as an item (container by default) contained by the photographed item. Not yet:
QR scanning, Sign in with Apple (Phase 13 wired server-side; the native button
arrives with the Apple Developer account), TestFlight/device signing.*

1. **Workspace layout** *(wired 2026-08-09, ahead of execution)*:
   `inventory-mobile-apps/` is a superproject submodule holding `inventory-ios-app`
   and `inventory-android-app` as nested submodules — placeholder commits
   until their phases execute; remotes are empty until the first authorized push.
   *(Originally wired under `lawfulevilorg`; RELOCATED 2026-08-10 to
   `git@github.com:mykelalvis/*.git` — all branches moved, git-flow config and
   GitHub default branches preserved, .gitmodules repointed on both umbrella
   branches, lawfulevilorg copies being removed.)* The Xcode
   project must build headless — `xcodebuild` with a scheme, simulator destination,
   and `CODE_SIGNING_ALLOWED=NO` for CI-shaped builds — never only from the IDE.
   *(Decided 2026-08-09: the project is generated by **XcodeGen** — `project.yml` is
   the source of truth, the generated `.xcodeproj` + shared scheme are committed, and
   `just ios-regen` regenerates. A compiling SwiftUI skeleton exists as of the same
   date: universal target, iOS 17 floor, sources typecheck on CLT-only machines; the
   full `just ios-build` gate runs wherever Xcode is installed.)*
2. **App v1 scope** (universal iPhone/iPad, SwiftUI):
   - Configurable web-api base URL; login via `POST /api/v1/auth/login` (token kept in
     the Keychain), logout.
   - Items list from `GET /api/v1/views/items` (search + pagination come free from the
     Phase 6 BFF); item detail from the one-call `/detail` view.
   - **QR scan** (VisionKit/DataScanner): scanning a printed label's
     `<base-url>/i/{id}` deep link opens the item in-app — the mobile half of the
     label loop.
   - Photo capture + asset upload rides the existing endpoints; the Phase 8 region
     model (when built) arrives for free through the same views. *(Added 2026-08-09)*
     At capture the app reads the device GPS (CoreLocation, when-in-use permission)
     and sends lat/long explicitly with the upload — the reliable source for Phase
     8's location suggestion, since EXIF rarely survives the upload path.
3. **Build/test tooling**: Justfile recipes `ios-build` (Debug, simulator, unsigned),
   `ios-test` (`xcodebuild test` on a simulator), `ios-open` — `[macos]`-gated with a
   preflight that explains what is missing (full Xcode vs CLT, or the scaffold itself
   before this milestone executes). RUNBOOK documents them.
4. **Tests**: unit tests for the API client (against canned JSON) and one
   `xcodebuild test` UI smoke: launch, log in against a stub/local web-api, items list
   renders. Gate: `just ios-build` and `just ios-test` green on the dev Mac; scanning
   a physical Brother label opens the right item on a real device.
5. **Deferred within this phase**: TestFlight/App Store distribution, push, universal
   links (needs the public HTTPS domain — tracked in Phase 11's checklist), offline
   mode.

## Twelfth milestone (Phase 13: Sign in with Apple + federated identity)

*Added 2026-08-13. Everything lands disabled-by-default and CI-testable without Apple
credentials; the flip-on is config + secrets only.*

1. **Schema (inventory-impl)** — changeset `012-user-identities.yaml`:
   `user_identities(provider text, subject text, user_id fk→users(id) cascade,
   PRIMARY KEY (provider, subject))` + index on `user_id`. `users` unchanged
   (`uq_users_email` stays; email remains profile data + legacy key).
2. **Store (inventory-impl)** — `UserStore` gains `findByIdentity(provider, subject)`,
   `linkIdentity(userId, provider, subject)`, and an indexed `findByEmail` (replacing
   the exchange's O(n) `list()` scan); implemented in both `PgUserStore` and
   `InMemoryUserStore`.
3. **Exchange (inventory-server)** — `POST /api/v1/auth/exchange` body gains optional
   `provider` + `subject`. Resolution order: `(provider, subject)` identity → email
   match (case-insensitive; links the new identity to the existing user) → provisioning
   policy (`invited` 403 / `auto` create + link). Legacy `{email, displayName}`-only
   bodies keep today's email-keyed behavior. Audit events carry the provider.
4. **Webapp (inventory-web-app)** — named tenant `quarkus.oidc.apple.*` with
   `provider=apple` under the `%oidc` profile, enabled by
   `INVENTORY_OIDC_APPLE_ENABLED` (default false; secrets via
   `QUARKUS_OIDC_APPLE_CLIENT_ID`, key file/kid/team-id env). New
   `GET /oidc/apple/login` (`@Tenant("apple")`); both login resources now pass
   `provider` + `sub` to the exchange. Apple quirk accepted: the display name arrives
   only in the first callback's `user` form field, which Quarkus does not surface —
   fall back to the email local part. Login page renders one button per enabled
   provider (`oidcEnabled` → per-provider flags).
5. **Tests** — mirror the established disabled-pattern: webapp `AppleOidcDisabledTest`
   (bounce + no button); server exchange tests for subject-match, email-link, relay-email
   provisioning, legacy body; store tests for the new methods in memory + Pg
   (Testcontainers).
6. **Gate** — `mvn verify` green locally and in CI with zero Apple config present;
   manual end-to-end Apple login deferred until the Apple Developer account exists
   (Phase 11 checklist) and a TLS-fronted redirect URL is available.

## Thirteenth milestone (Phase 14: formal releases)

*Added 2026-08-14. Everything stays inert until a `v*` tag is pushed; `develop` is
SNAPSHOT forever. Not yet executed.*

1. **CI-friendly versions.** Modules move from literal `0.0.1-SNAPSHOT` to
   `${revision}` (default `0.0.1-SNAPSHOT` set in `inventory-parent`), with
   `flatten-maven-plugin` (`flattenMode=resolveCiFriendliesOnly`) so installed poms
   carry resolved versions; `${inventory.version}` in the parent follows. A release
   build is just `mvn -Drevision=1.2.0 …` — no pom edits, no release plugin.
   *Gate: full `mvn verify` green both bare and with `-Drevision` set; flattened
   poms show the resolved version.*
2. **Release workflow.** `release.yml` in the superproject, triggered by tags
   matching `v*`: recursive checkout (SUBMODULE_TOKEN), build the reactor at
   `-Drevision=${tag#v}`, native-image the three apps
   (`-Dnative -Dquarkus.native.container-build=true`), `docker build` each
   `Dockerfile.native`, push to `ghcr.io/<owner>/inventory-root/<module>:<version>`
   plus `:latest`, stamped with `org.opencontainers.image.source` pointing at
   inventory-root so the packages group under it. `GITHUB_TOKEN` with
   `packages: write` does the push; **verify the three packages are Private in the
   GHCR UI after the first release** (user-account packages default private, but the
   gate is checking, not assuming). Draft a GitHub Release with the compose overlay
   snippet for that version. *Gate: pushing a `v0.0.1` pre-release tag produces
   three private packages under the inventory-root namespace and a green run.*
3. **Submodule tag mirroring.** The release ceremony (not CI) tags each submodule
   repo with the same `vX.Y.Z` at the SHA the superproject records — locally, so
   SUBMODULE_TOKEN stays read-only. *Gate: after a release, `git tag --contains`
   in any submodule finds the version at the recorded pointer.*
4. **`just release <version>`.** The one command: refuses on a dirty tree or off
   `develop`/`master`, runs the full verify, optionally drives the git-flow
   release-branch ceremony (`git flow release start/finish`), creates the
   superproject tag + mirrored submodule tags, and prints exactly what to push
   (nothing pushes without the user's say — house rule). *Gate: dry-run mode shows
   the plan; a real run on a scratch tag produces the tags locally.*
5. **Compose consumes releases.** `docker-compose.release.yml` overlay (or
   `IMAGE_TAG` env) runs the stack from pulled
   `ghcr.io/<owner>/inventory-root/<module>:<version>` images instead of local
   builds — the deploy path for anything that isn't the dev machine. *Gate:
   `docker compose -f docker-compose.yml -f docker-compose.release.yml up` serves
   the smoke flow from pulled images.*
6. **Devcontainer image joins the namespace.** `devcontainer-image.yml` publishes to
   `ghcr.io/<owner>/inventory-root/inventory-devcontainer:latest`; `ci.yml`'s
   container reference follows. (Tooling image: still `:latest`-only, not
   release-versioned.) *Gate: CI green pulling the renamed image.*
7. **Release runbook.** RUNBOOK section: cutting a release, verifying package
   visibility, rolling back (retag/delete package version), and the
   consumer-of-record note (compose overlay). *Gate: doc review against a real
   release.*

**Out of scope, own phases later**: iOS store releases (TestFlight/App Store,
`MARKETING_VERSION`, signing — after the Phase 11 checklist lands), Android store
releases, and any Maven artifact publishing (only if an external consumer ever
needs the jars; GitHub Packages is the answer then).

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
4. **Hardware** — the only stage requiring metal: a manual smoke checklist in the Phase 7
   runbook. *(Resolved 2026-08-08: the vendor is the Brother PT-P750W — see the decision
   row and the tenth milestone; stage 2's first real dialect is Brother raster, with ZPL
   kept as the Labelary-testable reference.)* The architecture stays behind the existing
   `LabelPrinter` interface regardless.

## Verification

- `mvn clean verify` at the workspace root: all modules green.
- `quarkus dev` in `inventory-server`: `GET /q/openapi` serves the contract; full CRUD
  round-trip via curl with the dev token; an audit row exists for every mutation.
- Second milestone: `quarkus dev` in webapp + server; log in via the browser, browse
  from an item to a subitem and back via its container link, move an item between
  containers and see both container pages update; server log shows `item.move` audit.
- Liquibase: a fresh Postgres container reaches current schema from empty; rolling back
  the latest changeset succeeds (README's forward-and-possibly-backward migration goal).
- Phase 5 gate: after the UI move, the aggregator is green, `quarkus dev` in webapp +
  web-api + server still passes the second-milestone browser flow, and
  `inventory-web-api` serves no HTML pages (JSON/auth only).
- Phase 6 gate: the item-detail page renders from one web-api call (stub request-count
  assertion); items list paginates and searches; no aggregation or derivation code
  remains in `PageResource`; aggregator green.
- Phase 7 gate: `mvn verify -Dnative` produces a native executable that passes the same
  integration tests; container restarts (cold and warm) lose no committed data.
- Phase 8 gate: in `quarkus dev` — upload a space photo, draw a box, name it, and the
  new item exists, contained in the space's container, with its region linked and an
  `item.create-from-region` audit row; `mvn verify` runs the island build and its tests.
- Phase 9 gate: without hardware — golden-file compose tests, exact-byte raster encoder
  tests, and the fake-9100 capture test all green (JVM and native). With hardware — a
  printed label whose QR phone-scans through `/i/{id}` to the item page.

## Open unknowns (tracked, not blocking)

- **Locations vs. unified containment** — see the "Decision needed SOON" section
  at the top of this plan. Unlike the rest of this list it IS time-sensitive: the
  migration cost compounds with data volume and client count, so it should be
  decided before inventory is widespread.
- ~~iOS/Android app stack~~ — both decided 2026-08-09 with compiling skeletons:
  native SwiftUI universal (iOS, Phase 12) and native Kotlin + Jetpack Compose
  (Android, its own phase). Remaining open: mobile app timeline/scope beyond the
  skeletons. When mobile CI arrives, iOS needs macOS runners — the Phase 10
  devcontainer covers only the Linux-friendly lanes (Android's Gradle build could
  join Linux CI once the SDK is added to the image).
- ~~Label-printer protocols/vendors to support~~ — resolved 2026-08-08: Brother
  PT-P750W first (raster protocol over TCP 9100); ZPL remains the reference dialect for
  a future Zebra-class device. Open sub-question: whether ~18 mm QRs on 24 mm tape scan
  reliably enough, or labels need larger media (answered by the Phase 9 hardware smoke).
- Deployment target among swarm/nomad/k8s (manifests kept portable until chosen).
- Asset storage backend (object store vs. Postgres) — decided in Phase 3.
- ~~Long-term web UI framework/language~~ — decided 2026-08-07 (Web UI direction row):
  island architecture, Svelte islands, SvelteKit only at a majority-interactive tipping
  point. Remaining sub-unknown: none until an island exists; revisit after Phase 8.
- Repo naming caution *(resolved 2026-08-09: directory, submodule, AND Maven
  artifactId all renamed to `inventory-web-app`, matching the GitHub repo)*: the
  unhyphenated `inventory-webapp` GitHub URL is still a redirect to
  `inventory-web-api` — never push to it. The Java package
  (`org.lawfulevil.inventory.webapp`) and the `inventory.webapp.*` config keys keep
  the old spelling deliberately — renaming those is behavioral, not cosmetic.
  *(Bite recorded 2026-08-09: a stale pre-rename `inventory-webapp-*-runner` binary
  lingered in target/, and Dockerfile.native's `COPY target/*-runner` glob matched
  BOTH — the stale one sorted last and silently won, shipping a pre-island native
  image. Removed; `mvn clean` after renames, or tighten the glob, prevents a repeat.)*
