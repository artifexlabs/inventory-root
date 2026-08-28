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
| Remove build output | `just clean` *(the four app modules)* · `just clean-libs` *(the lib submodules `inventory-parent`, `inventory-api`, `inventory-impl-root` — never `../artifex-parent`)* |
| JVM build + tests | `just verify` *(builds the lib repos in order via `just libs`, then `mvn -B verify` on the app reactor)* |
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

## Build images

```sh
mvn -pl inventory-server,inventory-web-api,inventory-projector -am package -DskipTests   # JVM fast-jars (bus members)
mvn -pl inventory-web-app -am package -DskipTests -Dnative -Dquarkus.native.container-build=true
docker compose --project-directory . -f deploy/docker-compose.yml build
```

The three bus members (gateway, server, projector) ship as JVM containers: the
vertx-infinispan cluster manager is the one component not yet proven under GraalVM
native. The web-app stays native (`native` profile — since 2026-08-18 it lives
in `io.artifexlabs:artifex-maven-parent`, the new grandparent, not
`inventory-parent`; `-Dnative` activates it). The server's native Dockerfile still exists for a future
single-process/native experiment and installs `fontconfig` + `dejavu-sans-fonts` —
required for label text rendering (quarkus-awt).

## Bring up / tear down

```sh
docker compose --project-directory . -f deploy/docker-compose.yml up -d      # postgres -> liquibase migrate (runs, exits 0) -> the three apps
docker compose --project-directory . -f deploy/docker-compose.yml ps         # all Up; migrate shows Exited (0)
docker compose --project-directory . -f deploy/docker-compose.yml down       # stop stack, KEEP data
docker compose --project-directory . -f deploy/docker-compose.yml down -v    # stop stack, DESTROY database volume
```

Ports: web-api (gateway) 8081, webapp 8082, projector 8083; inventory-server has no
published port (internal health only — all its work arrives over the bus fabric).
Browser entry: http://localhost:8082
(login with the seeded admin, default `admin@example.com` / `change-me` — override via
`INVENTORY_ADMIN_EMAIL` / `INVENTORY_ADMIN_PASSWORD`).

## Smoke flow (the standing check)

```sh
TOKEN=$(curl -s -X POST localhost:8081/api/v1/auth/login \
  -H 'Content-Type: application/json' \
  -d '{"email":"admin@example.com","password":"change-me"}' | sed -E 's/.*"token":"([^"]+)".*/\1/')
curl -s -H "Authorization: Bearer $TOKEN" localhost:8081/api/v1/items            # CRUD read (gateway → bus → server)
ID=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"smoke-item","type":"tool"}' localhost:8081/api/v1/items | sed -E 's/.*"id":"([^"]+)".*/\1/')
curl -s -H "Authorization: Bearer $TOKEN" localhost:8081/api/v1/items/$ID/qr.png -o /tmp/qr.png
file /tmp/qr.png                                                                 # PNG image data
curl -s -X POST -H "Authorization: Bearer $TOKEN" localhost:8081/api/v1/items/$ID/print-label -w '%{http_code}\n'
curl -s -H "Authorization: Bearer $TOKEN" "localhost:8081/api/v1/views/items?query=smoke" # BFF view
```

QR gate: decode `/tmp/qr.png` with zxing and confirm it encodes
`$INVENTORY_QR_BASE_URL/i/$ID` (the JVM-side `QrAndLabelTest` checks the same
round-trip on every build).

**PRINT-DISCIPLINE WARNING (learned 2026-08-18):** the smoke's `print-label`
step dispatches a REAL print. If `.env` points `INVENTORY_PRINTER` at hardware
(as it does whenever you have been doing printer work), `just smoke` will
consume a physical label — and at whatever `INVENTORY_PRINTER_FORMAT` says,
which may not match the stock currently loaded. Bring the stack up with
`INVENTORY_PRINTER=log` for routine verification:
`INVENTORY_PRINTER=log docker compose --project-directory . -f deploy/docker-compose.yml up -d`
(shell environment beats `.env` in compose substitution). The smoke is
asserting that the label pipeline dispatches and audits — the log printer
proves that without spending stock.

Related trap on the build side: `just verify`, `just fastjars`, and
`_sync-libs` all run Maven tests, and `dotenv-load` would otherwise feed them
the same hardware config — so they go through the Justfile's `test_env`,
which unsets the OIDC and printer variables. Unit tests must see the
UNCONFIGURED defaults. Note `-DskipTests` does NOT skip anything here
(ibparent-root hard-pins `<skipTests>false</skipTests>`); only
`-Dmaven.test.skip=true` does.

## Restart drills

- **Warm** (process bounce, data intact):
  `docker compose --project-directory . -f deploy/docker-compose.yml restart inventory-web-api` → smoke flow passes; previously created
  items still present.
- **Cold** (full stack down, volume kept):
  `docker compose --project-directory . -f deploy/docker-compose.yml down && docker compose --project-directory . -f deploy/docker-compose.yml up -d` → migrate re-runs idempotently
  (no-op), data intact.
- **From empty**: `docker compose --project-directory . -f deploy/docker-compose.yml down -v && docker compose --project-directory . -f deploy/docker-compose.yml up -d` → Liquibase builds
  the schema from nothing; seeded admin can log in.

## Backup / restore

```sh
# Backup (while running)
docker compose --project-directory . -f deploy/docker-compose.yml exec postgres pg_dump -U inventory -Fc inventory > inventory-$(date +%F).dump
# Restore (into a fresh volume)
docker compose --project-directory . -f deploy/docker-compose.yml down -v && docker compose --project-directory . -f deploy/docker-compose.yml up -d postgres
docker compose --project-directory . -f deploy/docker-compose.yml exec -T postgres pg_restore -U inventory -d inventory --clean --if-exists < inventory-YYYY-MM-DD.dump
docker compose --project-directory . -f deploy/docker-compose.yml up -d
```

## Migrations (day-2)

Forward: add a changeset (with rollback) under
`inventory-impl-root/inventory-impl-changeset/src/main/resources/db/changeset/`, include it in
`db/changelog-master.yaml`, rebuild the changeset jar (`just libs`), then
`just migrate` (or `just up` — migrate always runs before the server).
The migrate container is the `inventory-migrate` image — Liquibase with the
changeset JAR on its classpath (no bind mount); `just migrate` passes
`--build` so the image refreshes from the current jar.

Backward:
```sh
just rollback 1   # confirm-gated; also --build
# raw form:
docker compose --project-directory . -f deploy/docker-compose.yml run --rm --build migrate --url=jdbc:postgresql://postgres:5432/inventory \
  --username=inventory --password=$POSTGRES_PASSWORD \
  --changelog-file=db/changelog-master.yaml \
  rollback-count 1
```

## Hardware label-printer smoke (Brother PT-P750W)

Vendor resolved 2026-08-08: Brother PT-P750W (Wi-Fi, raw TCP 9100, Brother raster
protocol; TZe tape ≤ 24 mm at 180 dpi). **Steps 1–3 PASSED 2026-08-09**: printer on
the LAN at 10.0.1.130 (in the workspace `.env` — update there if DHCP moves it),
`just print-label` printed a physical 414-line label and returned 204 (now 202 — MORE_VERTX) with the
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
just ios-test     # xcodebuild test on a simulator (INVENTORY_IOS_SIMULATOR, default "iPhone 17")
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

## The event-bus fabric (migrate_to_vertx_eb topology)

The clustered Vert.x bus is now the deployment's spine, carrying two distinct
kinds of traffic (see [deploy/DEPLOYMENT.md](deploy/DEPLOYMENT.md) for the full deploy method):

1. **Request/reply envelopes** (`inventory.svc.*`): every HTTP request the
   gateway (`inventory-web-api`) authenticates becomes a `BusEnvelope` — action,
   target id, typed payload, acting user, asserted roles, shared fabric token —
   answered by `inventory-server`'s workers (CRUD, audit, QR/label, users,
   tokens, auth). Workers refuse bad fabric tokens (401) and missing roles (403)
   before touching the domain.
2. **After-commit facts** (`inventory.events.*`): unchanged publish-only
   announcements; the `audit_events` table stays the durable log of record.

`inventory-projector` (:8083) is the reference fact consumer: it pages
`audit_events.seq` from a durable cursor and lands `item.*` / `label.print`
facts in its `projections` table exactly once. **Poll-only mode remains fully
correct** for consumers; cluster membership is their latency upgrade. The
gateway, in contrast, REQUIRES the fabric — no workers, no API.

- The three bus members (gateway .11, server .12, projector .13) hold static IPs
  on the internal-only `cluster` network (172.28.0.0/24): static addressing pins
  JGroups membership (:7800), TCPPING discovery, and the separate Vert.x
  event-bus message transport (:15701, whose localhost default silently drops
  remote deliveries).
- **Ports**: JGroups TCP 7800 (+`FD_SOCK2` at 57800) and bus transport 15701 —
  cluster network only, NEVER published. Bus membership is access; the network
  is the security boundary; the envelope fabric token is defense in depth.
- **Symptoms**: `ISPN000094: Received new cluster view ... (3)` everywhere =
  healthy trio. Repeated view churn or `(1)` views = split brain — check
  `jgroups.tcpping.initial_hosts` lists all three static IPs and that every
  member sits on the `cluster` network. During a partition: gateway requests
  fail 503 (nothing is silently dropped — request/reply has no store-and-forward);
  facts are NOT lost — the projector's reconciliation poll sweeps the table.
- **Consumer recovery is trivial by design**: a consumer is just a cursor. Wipe
  or reset its `consumer_cursors` row and it replays idempotently from wherever
  you point it (`seq = 0` = full history).
- Config: `inventory.bus.workers` = `embedded` (single-process dev/test) |
  `remote` (deployment); `inventory.bus.token` (shared fabric token);
  `inventory.events.bus` = `none` (default) | `local` | `clustered`; projector
  poll interval `inventory.projector.poll-interval-ms`.

## Hashing a data medium (PLAN.md Phase 23)

Describing a medium is fast; hashing it is not. `find` lists a 120 TB tree in
minutes and reads nothing; hashing that tree reads every byte and takes **weeks**.
The two are deliberately separate jobs, and everything below assumes the second
one gets interrupted — discs get unplugged, machines reboot, workers get killed.

### Describe first (cheap, no reads)

```sh
find /mnt/x -type f        -printf '%s\t%TFT%TT\t%p\n'  >  manifest.tsv
find /mnt/x -type d -empty -printf '\t\t%p/\n'          >> manifest.tsv
curl -X PUT --data-binary @manifest.tsv -H 'Content-Type: text/plain' \
  "$API/api/v1/items/$ITEM/data/manifest"
```

The trailing `/` on the second line is not cosmetic: it is the only way an EMPTY
directory can be named, and without it two media differing only by an empty
folder produce identical structure hashes.

**Duplicate-section answers work from this point on**, before a single byte is
hashed — structure matching uses names and sizes only.

### Then hash (slow, restartable)

**`inventory-hasher` is the worker**, and it runs **on the machine the medium
is mounted on** — not on the server. The disc is in your hand; shipping 120 TB
across the network so the gateway can read it is not a design. That machine
therefore needs the same store access the server has: the worker talks to
Postgres directly, and there is deliberately no HTTP route that claims or
completes work, because a claim is a lease and leases do not survive being
proxied. It claims a batch, reads those files, and completes them. Claims are
committed rather than held, so nothing is lost by killing it:

```sh
# build once (workspace): mvn -pl inventory-hasher package
# then ship inventory-hasher/target/quarkus-app to the machine with the medium
export QUARKUS_DATASOURCE_REACTIVE_URL=postgresql://inventory-host:5432/inventory
export QUARKUS_DATASOURCE_USERNAME=inventory QUARKUS_DATASOURCE_PASSWORD=...

java -jar quarkus-run.jar hash --item $ITEM --root /mnt/x
java -jar quarkus-run.jar progress --item $ITEM     # one line, then exits
```

An archive is the identical call against the archive's OWN item, with
`--archive /mnt/x/backup.zip` instead — which is the whole reason archives are
items. Exit codes tell the medium's story: `0` finished what could be finished
(the summary says whether it is intact), `3` medium absent — nothing was
marked, `4` stale manifest — re-describe with a fresh `find`, don't retry.

A run ends by sweeping the directory rollup, so the content answers below stay
current without a second command. `POST /api/v1/items/$ITEM/data/rollup` forces
one by hand if you loaded hashes some other way.

| you want to | do |
|---|---|
| see progress | `GET /api/v1/items/$ITEM/data/progress` — `pending`, `claimed`, `done`, `unreadable`, `fraction`, `complete`, `intact` |
| pause | stop the worker. In-flight claims expire on their own; nothing is corrupted |
| resume | start it again. It claims whatever is still pending — there is no separate resume command, and a run begins by reclaiming expired claims, so crash recovery is the same command |
| recover after a crash | nothing. Stale claims return automatically once their lease lapses |
| abandon a medium | stop the worker and leave it. A partly hashed medium is valid: structure answers still work, content answers cover what finished |

`complete` means nothing is left to do. `intact` means that AND nothing was
unreadable — a medium can be the first and not the second, which is why they are
separate fields rather than one.

### Then ask what is duplicated

```sh
# the whole inventory
curl "$API/api/v1/data/sections?match=structure"
# just this medium's content, wherever else it lives
curl "$API/api/v1/items/$ITEM/data/sections?match=structure&scope=within_medium"
```

`match` is `structure` (names and sizes — answerable the moment the manifest
lands, before a byte is hashed), `merkle` (names and content: proof) or
`content` (content only, so renamed files still match). `scope` is
`across_media`, `within_medium` or `both`.

**`merkle` and `content` are empty until the rollup has swept**, and a subtree
with even one unhashed file has no content identity at all — deliberately, so a
digest never changes meaning as a run proceeds. A folder that was moved AND
renamed still matches: a directory's identity is what it holds, not its label.

### Then ask what you already have, and what you have lost

```sh
curl "$API/api/v1/items/$ITEM/data/overlap"   # how much of this disc is elsewhere
curl "$API/api/v1/items/$ITEM/data/repairs"   # what it could not read, and who has it
```

`overlap` is per-MEDIUM: `sharedEntries`/`sharedBytes`, plus `identical` (the
same tree all the way down) and `contains` (theirs is a superset — the "which
backup is newer" answer). Sameness here is same content at the same PATH, which
is the opposite of what `sections` does, and both rules are deliberate.

`repairs` lists every unreadable file with `recoverable: true|false`. **The
`false` rows are the ones that matter** — that damage cannot be restored from
anything catalogued. Matching is by path, because an unreadable file has no
content digest to match on; that is what unreadable means.

**`minFiles` defaults to 8 and lowering it is how you drown.** 46.7% of
directories on the measured tree hold two files or fewer, and 7,492 held nothing
but a `pom.xml`. `minDepth` does not substitute — those directories sit at every
depth.

**`pending` reaching zero with `unreadable` above zero means the run is over but
the medium is NOT intact.** Those two counts are kept apart on purpose —
conflating them would hide damage. What could not be read is listed per file in
`data_unreadable`, with the reason and an attempt count, and that list is
actionable: a file this disc cannot read may be readable on a sibling copy.

### Things that look wrong but are not

- **`claimed` stuck above zero after a worker dies.** Expected. The lease has to
  lapse before those rows return. Waiting is correct; intervening is not.
- **A file hashed on one run, pending on the next.** The medium was re-described
  and that file's size or mtime changed, so its old digest was dropped. That is
  the design: a digest describing bytes the file no longer has would be a lie
  nothing could detect later.
- **Archives showing `pending` long after their medium finished.** An archive is
  its own item with its own manifest. Listing it is cheap and happens at scan;
  hashing what is inside means decompressing, and it queues like anything else.
- **A run reporting `stale` above zero and stopping with files still pending.**
  Those files no longer match the manifest — their size or mtime moved — so the
  hasher refused to attach a digest to a row describing different bytes.
  Re-describe the medium; the fix is a fresh `find`, not a retry.
- **An unplugged disc reporting no damage.** Deliberate. The hasher checks the
  medium is present before it marks anything, because recording every path on an
  absent disc as unreadable would destroy the repair index that the unreadable
  list exists to be.
- **A damaged medium NOT matching an intact one that holds the same readable
  files.** Correct, and it takes work to be correct. An unreadable file
  contributes nothing to a Merkle, so the two digests genuinely agree; the
  damage carries its own digest alongside, and matching requires both. Two media
  damaged in the SAME places do match each other.

## Formal releases (Phase 14)

One `vX.Y.Z` tag on the superproject releases the whole platform. `develop`
stays `0.0.1-SNAPSHOT` forever (the `${revision}` default in
inventory-parent); release versions exist only at tags.

Cutting a release:

```bash
just release-plan 1.2.0    # checks + shows exactly what would happen
just release 1.2.0         # full verify at -Drevision=1.2.0, then tags:
                           #   v1.2.0 on the superproject (HEAD)
                           #   v1.2.0 in every submodule at its RECORDED SHA
```

Nothing pushes automatically (house rule). When ready:

```bash
git push origin v1.2.0                              # triggers release.yml
git submodule foreach 'git push origin v1.2.0'      # mirror tags
```

`release.yml` then: builds and installs the lib submodules
(parent → api → impl-root) at their own literal versions, builds the app
reactor at `-Drevision=1.2.0` (full verify), native-images
inventory-web-app, and pushes `artifexlabs/<module>:1.2.0` (+`:latest`) to
PUBLIC Docker Hub (decided 2026-08-21; formerly private GHCR) for
inventory-server, inventory-web-api, inventory-projector (JVM images — the
cluster manager is not yet proven under native) and inventory-web-app
(native). It ends by drafting a GitHub Release with the run-this-version
snippet. Images may be built from unreleased Maven artifacts — images are
removable/overwritable; Maven Central releases are not, and follow their
own ceremony (PLAN.md Phase 19).

After the FIRST release: verify the four `artifexlabs/*` repos on Docker
Hub carry the new tag and are public.

Running a released version (any machine — the images are public):

```bash
INVENTORY_VERSION=1.2.0 docker compose --project-directory . -f deploy/docker-compose.yml -f deploy/docker-compose.release.yml up -d
```

Rolling back a bad release: deploy the previous version with the overlay
(images are immutable — nothing needs rebuilding); delete the bad Docker
Hub tags and the draft release; delete the git tags
(`git tag -d v1.2.0` + `git push origin :refs/tags/v1.2.0`, same in
submodules) only if the version number is to be reused, which it normally
should not be.

The devcontainer image lives in the same namespace
(`ghcr.io/artifexlabs/inventory-root/inventory-devcontainer:latest`) but is
`:latest`-only — a tooling image, not a release artifact. Note: the path is
derived from `${{ github.repository }}`, so ANY rename or org transfer of the
superproject moves it — and ci.yml cannot pull until devcontainer-image.yml has
published at the new path at least once. Run
`gh workflow run devcontainer-image.yml` first, then re-run ci. This bit us on
the 2026-08-23 move to the artifexlabs org, exactly as it had on the original
rename into the namespace.

Mobile apps are deliberately NOT in this pipeline: iOS releases via
TestFlight/App Store and Android via Play Console, each with its own
versioning and signing, in their own future phases.

## Notes

- Orchestrator target decided 2026-08-17: "all three" until another method is
  available. `deploy/docker-compose.yml` stays the executable reference; a
  Nomad job (`deploy/nomad/`) and a Helm chart (`deploy/helm/inventory/`)
  translate it — both unvalidated by decision until such a cluster exists
  (see [deploy/DEPLOYMENT.md](deploy/DEPLOYMENT.md)).

## Releasing the libraries (the train)

`inventory-api`, `inventory-impl-root` and `inventory-bom` release
independently of the apps (PLAN.md Phase 19). A cross-cutting change means
five ORDERED steps, and `just` has one recipe per step:

```
just train-plan                       # read-only: pins, versions, preflight
just train-api        0.2.0           # -> publish in the portal
just train-impl 0.2.0 0.2.0           # -> publish in the portal
just train-bom  0.2.0 0.2.0 0.2.0     # -> publish in the portal
just train-apps 0.2.0                 # re-pins the four apps + clean verify
```

**Why it is not one command.** `central-publishing-maven-plugin` runs with
`autoPublish=false`, so each step only STAGES a bundle; a human publishes it
at https://central.sonatype.com/publishing/deployments before the next step
can resolve it. That pause is deliberate — it is what made a mis-staged
`inventory-api 0.1.0` droppable instead of permanent.

**Before you start:** export `MAVEN_GPG_PASSPHRASE`. `maven-gpg-plugin`
appends `--pinentry-mode error` in batch mode, so gpg may only use an
ALREADY-CACHED passphrase, and the agent's cache expires partway through a
build this long. `train-plan` and every step check this first.

Releases run from a local machine only: CI verifies, never releases, so no
signing key leaves the machine and nothing automated can publish
irreversibly. Nothing in these recipes pushes.
