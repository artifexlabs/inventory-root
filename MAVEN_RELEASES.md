# Maven artifact extraction — staged work plan

*Written 2026-08-17 (decisions taken the same day). This is a STAGING
document, the [UPC_CODE.md] lifecycle: when the work is scheduled it moves
into [PLAN.md](PLAN.md) as a milestone (or several) and this file retires.*

> **PARTIALLY EXECUTED 2026-08-18 — out of the staged order.** The owner
> moved `inventory-parent` OUT of the workspace (it now lives beside it at
> `../inventory-parent`, its own repo), removed it from the aggregator and
> from `.gitmodules`, and re-parented it onto
> **`io.artifexlabs:artifex-maven-parent`**. That forced step 2's literal
> parent versions immediately (see "What already happened" below): a
> property-valued parent version resolves ONLY through `<relativePath>`, so
> the moment the parent left the tree, all six modules failed with
> `Non-resolvable parent POM ... inventory-parent:pom:${revision}`.
>
> **FURTHER EXECUTED 2026-08-19.** inventory-api and inventory-impl followed
> the parent out (see "What already happened 2026-08-19" below): out of the
> reactor and `.gitmodules`, re-homed as fresh repos in the **artifexlabs**
> GitHub org, literal versions everywhere. Step 2 is now essentially done
> except publishing wiring; steps 1, 3, and 4 remain unstarted, and step 1
> (the impl core/-pg split) happens inside the impl repo.
>
> **PARTIALLY REVERSED later 2026-08-19** (owner: the out-of-workspace move
> "gains me nothing"): all three came back INTO the workspace as
> `.gitmodules` submodules — but stay OUT of the reactor, keep their
> artifexlabs-org repos, fresh histories, and literal versions. So the
> lasting shape is: submodules for ergonomics, prebuilt libs for the build
> (`just libs` → reactor). Also: **artifex-maven-parent 2 released to Maven
> Central** (`io.artifexlabs.parents`); inventory-parent now pins 2.
>
> **STEP 1 EXECUTED 2026-08-19.** The owner created the
> **`inventory-impl-root`** aggregator repo (artifexlabs org, main+develop,
> git-flow'd), moved `inventory-impl` inside it, and detached impl's own
> git history (`.git` → `.git.old`, kept locally). The core/`-pg` split was
> then executed inside it: `inventory-impl-root` (pom aggregator) →
> `inventory-impl` (core) + `inventory-impl-pg` (Pg backends + changelogs).
> The standalone `artifexlabs/inventory-impl` GitHub repo is DEFUNCT —
> archive it, don't delete it.

*This activates the "revisit" clause of the Phase 14 decision ("no Maven
artifact repository is needed — revisit only if an external build ever
consumes the jars"): the owner intends the domain code to release as real
Maven artifacts via maven-release-plugin, with the apps consuming them.*

## Decisions (locked 2026-08-17)

| Decision | Choice | Rationale |
|---|---|---|
| Impl module shape | **Multi-module build, ONE version**: `inventory-impl` (core) + `inventory-impl-pg` (Pg code + changesets), released atomically | Artifact separation without version separation. The changelog↔SQL cohesion is real, but the memory/Pg twins and their parity tests must stay in one test run (the refusal-precedence divergence class). Repo separation later is possible but doubted. |
| Extraction scope | **Full extraction at once**: inventory-parent, inventory-api, inventory-impl leave the reactor and `${revision}`, get literal release-plugin-managed versions; the four apps keep the Phase 14 tag→images flow and consume released jars | The real change is versioning/release process — the modules already live in separate git repos. Parent must come along: a released artifact cannot have a `${revision}`/SNAPSHOT parent. |
| Snapshots *(REVERSED 2026-08-21, owner decision)* | **NO snapshot repository.** Everything is aggregated in the inventory-root workspace and built from source (`just libs` locally, the same chain in CI) | With one workspace as the only consumer, a shared SNAPSHOT channel adds credentials and drift for nothing; released artifacts are the only published form. |
| Releases *(DECIDED 2026-08-21 — the step-5 gate is closed)* | **Maven Central, PUBLIC** — every Java artifact under `io.artifexlabs.inventory`, published via the owner's existing Central account (`infrastructurebuilder`) and its signing keys | The namespace is verified and already deployed-to; the repos are already public; sources-jar publication is accepted (Apache-2.0 headers throughout). |
| Container releases *(added 2026-08-21)* | **Docker Hub, `artifexlabs` user** for released images (auth: an owner-held Docker Hub PAT, deliberately not recorded here) | Public images beside public artifacts; supersedes Phase 14's private-GHCR destination for RELEASES — release.yml migrates at execution. |
| Namespace *(REVERSED 2026-08-18, owner-accepted)* | **`io.artifexlabs.inventory`** — was `org.lawfulevil.inventory`, renamed wholesale across every repo, package, and document | Collapses the release chain from TWO namespaces to ONE: artifexlabs.io verification is already required for artifex-maven-parent, so inventory now rides the same namespace instead of adding a second (lawfulevil.org) to verify and maintain. Breaking coordinate change, taken while the only consumers are in this workspace. |
| Upstream parent *(added 2026-08-18)* | **`io.artifexlabs:artifex-maven-parent` sits above inventory-parent, and is RELEASED ENTIRELY INDEPENDENTLY of inventory** | A shared parent for artifexlabs.io projects. Inventory consumes it like any third-party parent — it is NOT part of inventory's release ceremony, and inventory's release train must simply *depend on an already-released version of it*. |

## What already happened (2026-08-18)

- `inventory-parent` relocated to `../inventory-parent` (sibling of this
  workspace, still its own git repo); dropped from the aggregator's
  `<modules>` and from `.gitmodules`. It is no longer a submodule of
  inventory-root.
- Its parent is now `io.artifexlabs:artifex-maven-parent:1-SNAPSHOT`
  (was `org.infrastructurebuilder:ibparent:112`, which artifex now parents
  off instead).
- **Config split**: artifex-maven-parent took over the Quarkus BOM import,
  the `native` profile, flatten's *configuration*
  (`resolveCiFriendliesOnly` / `updatePomFile`), and the shared build
  properties. inventory-parent kept `${revision}` / `${inventory.version}`,
  the inventory dependencyManagement, and flatten's *executions*.
- **The six modules now carry a LITERAL parent version** —
  `<version>0.0.1-SNAPSHOT</version>` with `<relativePath/>` — plus their
  own `<version>${revision}</version>`, which they previously inherited.
  Both halves are load-bearing: literal is the only form resolvable from a
  repository, and the restored own-version is what keeps Phase 14's
  `mvn -Drevision=X.Y.Z` versioning the platform (verified: bare →
  `0.0.1-SNAPSHOT`, `-Drevision=9.9.9-scratch` → `9.9.9-scratch`).
- **Each module also had to define `<revision>` locally.** Restoring
  `<version>${revision}</version>` alone broke every Quarkus module with
  `UnresolvedVersionException: Failed to resolve version '${revision}'`:
  Quarkus's bootstrap builds its workspace model from RAW poms, and once the
  pom defining `${revision}` sits outside the workspace, Quarkus has nowhere
  to interpolate it from. Maven itself was fine — this is a Quarkus
  workspace-discovery constraint, and it applies to EVERY module in the
  reactor (fixing only the failing one just moved the error to the next
  module). The standard workaround is a local
  `<properties><revision>0.0.1-SNAPSHOT</revision></properties>` in each
  module; `-Drevision=X.Y.Z` still overrides it, since command-line
  properties beat pom properties.
- **Consequence — a per-release chore**: every future inventory-parent
  version bump now requires editing that literal `<parent><version>` in all
  six modules, and the default `<revision>` now appears in seven poms
  (parent + six). That is the "multi-release ceremony" cost this document
  already recorded, arriving early. The BOM step (staged step 3) is what
  eventually tames it.
- **Local prerequisite**: `../artifex-parent` and `../inventory-parent` must
  be `mvn install`ed (or resolvable from a repository) before this reactor
  builds. CI cannot build inventory until artifex-maven-parent and
  inventory-parent are published somewhere it can reach — see Blockers.

## What already happened (2026-08-19)

- **inventory-api and inventory-impl extracted**: removed from the
  aggregator's `<modules>` and from the reactor build. *(They briefly left
  the workspace tree entirely; reversed the same day — all three are
  `.gitmodules` submodules again, exactly the "submodules stay in the
  workspace" line under Target architecture. Only the REACTOR exclusion
  stands.)*
- **All three repos re-homed to the artifexlabs GitHub org as FRESH repos**:
  the owner deleted each `.git` and re-established the current revision as a
  new first commit (`git@github.com:artifexlabs/inventory-{parent,api,impl}.git`).
  Pre-extraction history survives only in the old `mykelalvis` org repos —
  keep those archived, not deleted. git-flow (git-flow-next) initialized in
  each: `main` as the main branch, `develop` as the development branch —
  note this differs from the superproject's `master`/`develop` convention.
- **Literal versions everywhere** (the release-plugin precondition):
  inventory-parent is `1-SNAPSHOT` (its parent: released
  `artifex-maven-parent:1`); inventory-api and inventory-impl are
  `0.1.0-SNAPSHOT`; the parent's `<inventory.version>` is the literal
  `0.1.0-SNAPSHOT` feeding its dependencyManagement. `${revision}` now
  exists ONLY in the four app modules (each with its local default
  `0.0.1-SNAPSHOT`) — the Phase 14 `-Drevision` tag flow now versions the
  apps alone.
- **Propagation fixes applied after the move** (the restructuring left the
  build broken): the aggregator still listed `inventory-impl` as a module
  (directory deleted → reactor could not build); inventory-web-api and
  inventory-exporter still pinned parent `0.0.1-SNAPSHOT` (would have
  silently resolved the STALE pre-move parent from `~/.m2`); stale unused
  `<revision>` properties removed from all three extracted poms;
  `<relativePath/>` added to impl's parent block.
- **Justfile build chain reworked**: `just libs` installs
  parent → api → impl in order (with tests); `_sync-libs` is the fast
  no-test variant (dev/fastjars/native prerequisite); `just verify` = libs
  then app reactor; `clean` stays workspace-only and `clean-libs` cleans the
  three lib repos (`../artifex-parent` is never touched).

## What already happened (2026-08-19, later — step 1)

- **inventory-impl-root created by the owner** and wired as the impl repo of
  record: `git@github.com:artifexlabs/inventory-impl-root.git`, `main` +
  `develop`, git-flow initialized; `.gitmodules` swapped `inventory-impl` →
  `inventory-impl-root`. impl's previous standalone history is preserved
  locally in `inventory-impl/.git.old` and in the now-DEFUNCT
  `artifexlabs/inventory-impl` repo (archive it).
- **The split** (this document's step 1, executed in the new layout):
  - `inventory-impl-root` — pom aggregator, parent `inventory-parent`,
    literal `0.1.0-SNAPSHOT`; the future release-plugin
    `autoVersionSubmodules=true` root.
  - `inventory-impl` (core) — re-parented onto the aggregator, version
    inherited; keeps domain impls, InMemory twins, bus verticles,
    label/QR/catalog machinery, Gtin/Ulid, and the Ulid native-image
    config. **Sheds** `smallrye-mutiny-vertx-pg-client` and the whole
    Testcontainers/Liquibase/JDBC test surface.
  - `inventory-impl-pg` — the six `Pg*` classes (same
    `io.artifexlabs.inventory.impl` package), `db/**` changelogs in
    resources (changelog-in-jar is now REAL), `PgInventorySystemTest`
    (Testcontainers + Liquibase — already classpath-based, so it worked
    unchanged). Depends on core at `${project.version}`.
  - *(Step 1b, accepted + executed later 2026-08-19)*: the `db/**`
    changelogs moved again, into **`inventory-impl-changeset`** — a
    resources-only third module with no code and no dependencies; `-pg`
    depends on it, so every existing classpath still sees
    `db/changelog-master.yaml` transitively, and step 4's migrate image
    can consume the schema WITHOUT pg-client/core. Deploy mounts point at
    `inventory-impl-root/inventory-impl-changeset/src/main/resources`.
    Deliberately no code moved: every Pg* class is pg-client-coupled and
    no vendor-neutral code existed.
  - Parity note: the memory twin's test stays in core, the Pg twin's in
    `-pg` — one aggregator reactor run still executes both, which is what
    the one-version decision was protecting.
- **Consumers rewired**: inventory-parent's dependencyManagement gains
  `inventory-impl-pg` at `${inventory.version}`; server, web-api, and
  exporter (all construct `Pg*` backends) now depend on `-pg`; web-app
  depends only on `inventory-api` and needed nothing.
- **Path updates**: Justfile `lib_dirs` and ci.yml build
  `inventory-impl-root`; the compose migrate mount, Nomad checkout mount,
  and Helm copy-rule comments follow the changelogs to
  `inventory-impl-root/inventory-impl-pg/src/main/resources`.

## Blockers this created

1. **CI: FULLY RESOLVED 2026-08-19** (run 32252083378 green end to end:
   checkout, lib chain, artifex 2 from Central, reactor verify). The
   reversal restored parent/api/impl as submodules, so CI checks them out
   again and builds them from source (ci.yml runs the same
   parent → api → impl install chain as `just libs` before the reactor).
   The token risk retired itself: the owner made the three artifexlabs
   repos PUBLIC ("that's where they'll be eventually anyway" — consistent
   with the Central destination, which publishes source regardless), so
   the default token clones them. *(2026-08-21: the SNAPSHOT channel was
   dropped entirely — build-from-source is the permanent model until
   releases exist, so no publishing prerequisite remains at all.)*
2. **artifex-maven-parent pin: FULLY RESOLVED 2026-08-19** —
   `io.artifexlabs.parents:artifex-maven-parent:2` is released ON MAVEN
   CENTRAL and inventory-parent pins it. (Standing rule unchanged: artifex
   releases on its own clock; inventory pins whatever version is current
   when it releases.) Bonus: its presence on Central means the
   `io.artifexlabs` namespace verification already exists — one blocker
   under the release-destination gate is pre-cleared.
3. **Central namespace verification: CLEARED 2026-08-19** — the owner has
   verified `io.artifexlabs` on Central and already deployed to it. Since
   the 2026-08-18 rename it is the ONLY namespace in the chain, so this one
   verification covers parent and inventory alike. The release-destination
   gate (step 5) is now purely a publicness choice, with no verification
   work behind it.
4. **flatten-maven-plugin version: CLEARED 2026-08-19** — the pin is now
   inherited from ibparent-minimal at the top of the parent tree (owner
   confirmed; verified in the effective pom: pluginManagement carries
   `1.8.0` through artifex-maven-parent 2). Builds are reproducible on this
   axis again — no local action needed.

## Grounding facts (verified 2026-08-17)

- **ibparent-root 112's `release` profile** already attaches sources+javadoc
  jars (exactly what Central mandates) plus format validation. Activate with
  `releaseProfiles=release`.
- **Nothing publishes today**: no artifact `distributionManagement` (only a
  site), no GPG, no publishing plugin anywhere in the parent chain — all
  added fresh in inventory-parent.
- Every pom already carries `<scm>` wired to `${git.url}` — what
  maven-release-plugin needs.
- The Liquibase changelogs double as a **deploy-time artifact**: compose
  bind-mounts them, the Nomad job mounts a node checkout, the Helm chart
  carries hand-copies with a documented drift rule. Shipping them inside the
  `-pg` jar fixes that whole problem class.

## Target architecture

```
UPSTREAM, RELEASED ON ITS OWN CLOCK (not part of inventory's ceremony)
  io.artifexlabs:artifex-maven-parent
                            Quarkus BOM import, native profile, flatten
                            CONFIG, shared build properties; parents off
                            ibparent. Inventory pins a RELEASED version of
                            it before inventory-parent can itself release.

RELEASED ARTIFACTS (maven-release-plugin, literal versions)
  inventory-parent          ${revision}/${inventory.version}, inventory
                            dependencyManagement, flatten EXECUTIONS;
                            gains distributionManagement
  inventory-api             domain contracts
  inventory-impl-root       aggregator releasing its modules as one version
                            (BUILT 2026-08-19; changeset split same day):
    inventory-impl            core: domain impls, InMemory twins, bus
                              verticles, label/QR/catalog machinery, Gtin/Ulid
    inventory-impl-changeset  db/** Liquibase changelogs ONLY — no code, no
                              deps; the schema as a versioned artifact
    inventory-impl-pg         Pg* classes; depends on core + changeset
  inventory-bom             pins one coherent api+impl version set

SUPERPROJECT REACTOR (release model: v-tag -> images; destination moves
  GHCR -> Docker Hub `artifexlabs` for releases, decided 2026-08-21)
  inventory-server, inventory-web-api, inventory-exporter, inventory-web-app
  — import inventory-bom; depend on released jars (workspace source builds
  until the first release)
```

- Server/web-api/exporter depend on `inventory-impl-pg` (transitively core);
  memory-only consumers need only core. The web-app's native image sheds the
  pg-client/Liquibase/Testcontainers surface it never used.
- **inventory-bom** is the anti-skew replacement for the reactor's single
  `${revision}`: only BOM-pinned combinations (which CI verified together)
  ever deploy. Without it, `server` could resolve impl 1.3 + api 1.2 — a
  pair no build ever tested.
- Submodules stay in the workspace for ergonomics (one checkout, Justfile,
  IDE); only the aggregator/reactor shrinks to the four apps. *(Briefly
  reversed then restored 2026-08-19 — this is the standing shape: submodule
  checkouts, artifexlabs-org remotes, built by `just libs`, consumed as
  jars.)*

## Mechanics

- **distributionManagement** (in inventory-parent): Central ONLY — no
  snapshotRepository (decision 2026-08-21). The
  `central-publishing-maven-plugin` + the `infrastructurebuilder` account's
  existing GPG signing keys; `io.artifexlabs` namespace verification is
  already done (artifex-maven-parent 2 is on Central).
- **maven-release-plugin** per repo: `releaseProfiles=release` (rides
  ibparent's sources/javadoc profile), `tagNameFormat=v@{project.version}`,
  `autoVersionSubmodules=true` in inventory-impl-root so both modules
  version as one. `${revision}` + flatten-maven-plugin come OUT of the
  extracted poms (release-plugin rewrites literal versions; the apps' reactor
  keeps `${revision}` for the platform tag).
- **CI**: each extracted repo gets a small release workflow (verify →
  `release:prepare release:perform`) carrying the Central credentials +
  signing key. No snapshot-deploy job and no consumer `settings.xml`
  entries — between releases, everything builds from source in the
  workspace/CI exactly as today. release.yml's image publishing migrates
  from GHCR to the Docker Hub `artifexlabs` user at execution.
- **Verify at execution**: web-api's PgModeApiTest and the impl
  Testcontainers suites must read `db/changelog-master.yaml` from the `-pg`
  jar classpath (Liquibase classpath resolution) once the bind-mount
  assumption is gone from tests.
- **Dev inner loop**: unchanged and now PERMANENT — local `mvn install`
  of SNAPSHOTs via `just libs`; another machine gets them by building the
  same workspace from source. Visibility beyond the workspace happens only
  through real releases.
- **Build recipes must ALWAYS clean, because the IDE poisons target/**
  (added 2026-08-19 after a long false trail — this was the real "verify
  flake"): VS Code's Eclipse-JDT compiler writes `.class` files into
  `target/classes` even when sources DON'T resolve (during repo moves /
  submodule shuffles its workspace model breaks), baking in "Unresolved
  compilation problems" stubs whose unresolvable types are erased to bare
  simple names. Maven's incremental compile then trusts those newer
  `.class` files, and the stubs surface as phantom test-bootstrap errors
  (ArC "Producer method return type not found in index: UserStore", JUnit
  ClassSelector "Could not load class", Qute missing templates) in
  whichever module the IDE last rewrote — passing in isolation because
  isolation runs used `clean`. The Justfile's `verify`/`libs`/`_sync-libs`/
  `fastjars`/`native` now all run `clean` first; diagnostic: `javap -v`
  shows the "Unresolved compilation problems" string in the constant pool,
  or `grep -rl 'Unresolved compilation problem'` over target/classes.
- **Library jars ship a Jandex index** (also 2026-08-19): inventory-parent
  binds `io.smallrye:jandex-maven-plugin` (pinned 3.6.0) so every lib jar
  carries `META-INF/jandex.idx` and is a deterministic Quarkus application
  archive rather than relying on ArC's fallback indexing of external jars.
  Any future extracted library consumed by a Quarkus app inherits this.

## Costs accepted (recorded so nobody is surprised later)

- **The api↔impl seam is this codebase's hottest**: Phases 15, 16, and 17
  each changed contract + both backends + verticles + apps in one reactor
  pass. Post-extraction that becomes: release api → bump+release impl →
  bump apps (BOM) — a multi-release ceremony per cross-cutting feature.
  This is the price of independently consumable artifacts; the BOM and the
  atomic impl release train are the mitigations.
- Central releases are **irreversible and public** (with sources). The
  staged destination decision is the gate.
- New infrastructure to keep healthy: Central publishing credentials +
  GPG signing keys in the release workflows, a Docker Hub credential for
  image publishing, per-repo release workflows.
- `mvn clean verify` house rule matters MORE, not less: stale-compile masks
  across released-artifact boundaries surface only at consumer bump time.

## Staged execution steps (each a milestone-sized chunk when scheduled)

0. ~~URGENT: make CI satisfiable again (publish the parents).~~ **RETIRED
   2026-08-19**: the submodule reversal + artifex-maven-parent 2 on Central
   made CI buildable from source again (see Blockers #1). Only the
   `SUBMODULE_TOKEN` artifexlabs-org scope check survives from this step;
   GH-Packages SNAPSHOT publishing folds back into step 2 where it started.
1. **Impl goes multi-module.** ***EXECUTED 2026-08-19*** in the
   owner-created `inventory-impl-root` repo: aggregator + core + `-pg`,
   consumers rewired, changelog-in-jar real, impl reactor + app reactor
   green (see "What already happened (2026-08-19, later — step 1)").
2. **Release wiring.** *(MOSTLY DONE — parent 2026-08-18; api/impl
   2026-08-19: all three are out of the reactor in their own artifexlabs
   repos with literal versions, and the aggregator + Justfile now treat
   them as prebuilt libs.)* Remaining: artifact distributionManagement
   (today all three carry only a site entry — becomes Central-only per the
   2026-08-21 decision) + release-plugin config. No SNAPSHOT deploys (the
   channel was dropped); ci.yml keeps building libs from source until step
   3's releases let the apps pin Central coordinates.
3. **First releases + inventory-bom.** `release:prepare` dry-run, then real
   releases of parent → api → impl; BOM cut; apps pinned to it.
4. **Deploy-side payoff.** Migrate consumption switches to the versioned
   changelog (an `inventory-migrate` image or changelog-from-jar extraction)
   across compose/Nomad/Helm; the Helm copy rule and Nomad checkout mount
   retire.
5. ~~Gate: the release-destination decision.~~ **RESOLVED 2026-08-21 by
   owner decision: Maven Central, public, `io.artifexlabs.inventory`, via
   the `infrastructurebuilder` account and its signing keys; release
   images to Docker Hub `artifexlabs`.**

## Verification (for the eventual execution)

- Step 1: full reactor `mvn clean verify` + CI green; web-app native image
  builds without pg-client metadata; changelog present inside the `-pg` jar.
- Step 2: `release:prepare -DdryRun=true` parses cleanly with the new
  distributionManagement; a local `-DskipPublishing` staging run of the
  central-publishing plugin produces a valid, signed bundle.
- Step 3: `release:prepare -DdryRun=true` clean on all three repos; after
  real releases, the app reactor builds against BOM pins only.
- Step 4: `just smoke` green on compose with the migrate path consuming the
  versioned changelog; Helm README's copy rule deleted.

[UPC_CODE.md]: PLAN.md
