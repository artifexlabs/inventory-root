# Maven artifact extraction — staged work plan

*Written 2026-08-17 (decisions taken the same day). This is a STAGING
document, the [UPC_CODE.md] lifecycle: when the work is scheduled it moves
into [PLAN.md](PLAN.md) as a milestone (or several) and this file retires.
Nothing in the build changes until then.*

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
| Namespace | **`org.lawfulevil.inventory` stays** | Owner controls lawfulevil.org, so Central namespace verification (DNS TXT) is available if Central is chosen. |

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
RELEASED ARTIFACTS (maven-release-plugin, literal versions)
  inventory-parent          shared config; gains distributionManagement
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
  IDE); only the aggregator/reactor shrinks to the four apps.

## Mechanics

- **distributionManagement** (in inventory-parent):
  `<snapshotRepository>` → `https://maven.pkg.github.com/mykelalvis/inventory-root`
  (one shared Packages repo — GH Packages accepts any groupId under it);
  `<repository>` → the staged decision. When Central: the
  `central-publishing-maven-plugin` + GPG signing key, and one-time
  namespace verification for org.lawfulevil.
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

1. **Impl goes multi-module INSIDE the current reactor.** No release
   semantics yet: `inventory-impl-parent` + core + `-pg`, consumers'
   dependencies rewired, full reactor + CI green. Lowest-risk step,
   immediately useful (native web-app dependency hygiene, changelog-in-jar
   becomes buildable).
2. **Release wiring.** inventory-parent/api/impl move to literal versions;
   distributionManagement + release-plugin config; first SNAPSHOT deploys
   to GH Packages; superproject aggregator, Justfile, ci.yml shrink to the
   apps consuming coordinates instead of reactor paths.
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
