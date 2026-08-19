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

*This activates the "revisit" clause of the Phase 14 decision ("no Maven
artifact repository is needed — revisit only if an external build ever
consumes the jars"): the owner intends the domain code to release as real
Maven artifacts via maven-release-plugin, with the apps consuming them.*

## Decisions (locked 2026-08-17)

| Decision | Choice | Rationale |
|---|---|---|
| Impl module shape | **Multi-module build, ONE version**: `inventory-impl` (core) + `inventory-impl-pg` (Pg code + changesets), released atomically | Artifact separation without version separation. The changelog↔SQL cohesion is real, but the memory/Pg twins and their parity tests must stay in one test run (the refusal-precedence divergence class). Repo separation later is possible but doubted. |
| Extraction scope | **Full extraction at once**: inventory-parent, inventory-api, inventory-impl leave the reactor and `${revision}`, get literal release-plugin-managed versions; the four apps keep the Phase 14 tag→images flow and consume released jars | The real change is versioning/release process — the modules already live in separate git repos. Parent must come along: a released artifact cannot have a `${revision}`/SNAPSHOT parent. |
| Snapshots | **GitHub Packages** (private) | Same credential family as GHCR; internal-only consumers. |
| Releases | **STAGED — decide before the first release.** Central (permanently public; sources jars are mandatory, so every release is de-facto open-sourced under the existing Apache-2.0 headers, even with private repos) vs GitHub Packages (private; every consumer authenticates) | The trade-off is publicness, not mechanics — `distributionManagement` carries both targets either way. |
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

## Blockers this created

1. **CI: FULLY RESOLVED 2026-08-19** (run 32252083378 green end to end:
   checkout, lib chain, artifex 2 from Central, reactor verify). The
   reversal restored parent/api/impl as submodules, so CI checks them out
   again and builds them from source (ci.yml runs the same
   parent → api → impl install chain as `just libs` before the reactor).
   The token risk retired itself: the owner made the three artifexlabs
   repos PUBLIC ("that's where they'll be eventually anyway" — consistent
   with the Central destination, which publishes source regardless), so
   the default token clones them. Publishing to GitHub Packages is no
   longer a CI prerequisite; it returns to being step 2's SNAPSHOT-channel
   work.
2. **artifex-maven-parent pin: FULLY RESOLVED 2026-08-19** —
   `io.artifexlabs.parents:artifex-maven-parent:2` is released ON MAVEN
   CENTRAL and inventory-parent pins it. (Standing rule unchanged: artifex
   releases on its own clock; inventory pins whatever version is current
   when it releases.) Bonus: its presence on Central means the
   `io.artifexlabs` namespace verification already exists — one blocker
   under the release-destination gate is pre-cleared.
3. **If Central is chosen** at the release-destination gate, `io.artifexlabs`
   needs namespace verification (artifexlabs.io DNS TXT). Since the
   2026-08-18 rename this is now the ONLY namespace in the chain — parent and
   inventory alike — so one verification covers everything, rather than
   artifexlabs.io plus a separate lawfulevil.org.
4. **flatten-maven-plugin has no declared version anywhere in the chain**
   (ibparent manages none; artifex dropped it; inventory-parent only binds
   executions). Maven currently resolves it from metadata — it silently
   picked 1.8.0 on 2026-08-18 — so builds work but are not reproducible: a
   future release would change the build with no commit. Left alone per
   owner instruction ("unless it actually breaks something"); pinning it in
   artifex's `<pluginManagement>` is the fix when it matters.

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
  inventory-impl-parent     aggregator releasing BOTH modules as one version:
    inventory-impl            core: domain impls, InMemory twins, bus
                              verticles, label/QR/catalog machinery, Gtin/Ulid
    inventory-impl-pg         Pg* classes + db/ changelogs in resources
  inventory-bom             pins one coherent api+impl version set

SUPERPROJECT REACTOR (unchanged release model: v-tag -> GHCR images)
  inventory-server, inventory-web-api, inventory-exporter, inventory-web-app
  — import inventory-bom; depend on released (or GH-Packages SNAPSHOT) jars
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

- **distributionManagement** (in inventory-parent):
  `<snapshotRepository>` → `https://maven.pkg.github.com/mykelalvis/inventory-root`
  (one shared Packages repo — GH Packages accepts any groupId under it);
  `<repository>` → the staged decision. When Central: the
  `central-publishing-maven-plugin` + GPG signing key, and one-time
  namespace verification for io.artifexlabs.
- **maven-release-plugin** per repo: `releaseProfiles=release` (rides
  ibparent's sources/javadoc profile), `tagNameFormat=v@{project.version}`,
  `autoVersionSubmodules=true` in inventory-impl-parent so both modules
  version as one. `${revision}` + flatten-maven-plugin come OUT of the
  extracted poms (release-plugin rewrites literal versions; the apps' reactor
  keeps `${revision}` for the platform tag).
- **CI**: each extracted repo gets a small release workflow (verify →
  `release:prepare release:perform`) with a GH-Packages token, plus a
  SNAPSHOT-deploy-on-develop-push job. Consumer auth: a `settings.xml`
  server entry for GH Packages in ci.yml, the devcontainer, release.yml,
  and developer docs.
- **Verify at execution**: web-api's PgModeApiTest and the impl
  Testcontainers suites must read `db/changelog-master.yaml` from the `-pg`
  jar classpath (Liquibase classpath resolution) once the bind-mount
  assumption is gone from tests.
- **Dev inner loop**: the Justfile's `_sync-libs` evolves — day-to-day
  cross-repo dev = local `mvn install` of SNAPSHOTs exactly as today, with
  GH Packages as the shared SNAPSHOT channel when a change must be visible
  to CI or another machine before release.

## Costs accepted (recorded so nobody is surprised later)

- **The api↔impl seam is this codebase's hottest**: Phases 15, 16, and 17
  each changed contract + both backends + verticles + apps in one reactor
  pass. Post-extraction that becomes: release api → bump+release impl →
  bump apps (BOM) — a multi-release ceremony per cross-cutting feature.
  This is the price of independently consumable artifacts; the BOM and the
  atomic impl release train are the mitigations.
- Central releases are **irreversible and public** (with sources). The
  staged destination decision is the gate.
- New infrastructure to keep healthy: GH Packages tokens in four+ places,
  optional GPG key, per-repo release workflows.
- `mvn clean verify` house rule matters MORE, not less: stale-compile masks
  across released-artifact boundaries surface only at consumer bump time.

## Staged execution steps (each a milestone-sized chunk when scheduled)

0. ~~URGENT: make CI satisfiable again (publish the parents).~~ **RETIRED
   2026-08-19**: the submodule reversal + artifex-maven-parent 2 on Central
   made CI buildable from source again (see Blockers #1). Only the
   `SUBMODULE_TOKEN` artifexlabs-org scope check survives from this step;
   GH-Packages SNAPSHOT publishing folds back into step 2 where it started.
1. **Impl goes multi-module.** *(Re-scoped 2026-08-19: this now happens
   INSIDE the ../inventory-impl repo — it left the reactor before the
   split.)* No release semantics yet: `inventory-impl-parent` + core +
   `-pg`, consumers' dependencies rewired, impl repo + app reactor green.
   Still immediately useful (native web-app dependency hygiene,
   changelog-in-jar becomes buildable).
2. **Release wiring.** *(MOSTLY DONE — parent 2026-08-18; api/impl
   2026-08-19: all three are out of the reactor in their own artifexlabs
   repos with literal versions, and the aggregator + Justfile now treat
   them as prebuilt libs.)* Remaining: artifact distributionManagement
   (today all three carry only a site entry) + release-plugin config; first
   SNAPSHOT deploys to GH Packages; ci.yml shrinks to the apps consuming
   coordinates instead of reactor paths.
3. **First releases + inventory-bom.** `release:prepare` dry-run, then real
   releases of parent → api → impl; BOM cut; apps pinned to it.
4. **Deploy-side payoff.** Migrate consumption switches to the versioned
   changelog (an `inventory-migrate` image or changelog-from-jar extraction)
   across compose/Nomad/Helm; the Helm copy rule and Nomad checkout mount
   retire.
5. **Gate: the release-destination decision** (Central-public vs
   GH-Packages-private) — required before step 3's first non-SNAPSHOT
   release, with the publicness trade-off above.

## Verification (for the eventual execution)

- Step 1: full reactor `mvn clean verify` + CI green; web-app native image
  builds without pg-client metadata; changelog present inside the `-pg` jar.
- Step 2: a scratch SNAPSHOT deployed to GH Packages and consumed by a
  clean build of one app on a machine without the local ~/.m2 artifacts.
- Step 3: `release:prepare -DdryRun=true` clean on all three repos; after
  real releases, the app reactor builds against BOM pins only.
- Step 4: `just smoke` green on compose with the migrate path consuming the
  versioned changelog; Helm README's copy rule deleted.

[UPC_CODE.md]: PLAN.md
