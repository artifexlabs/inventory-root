# Migrating the Android build to Maven — feasibility and plan

*Written 2026-08-09. Status: PLAN ONLY — nothing in this document has been executed.
The Android app builds today via its committed Gradle wrapper
(`inventory-mobile-apps/inventory-android-app`, Kotlin + Jetpack Compose, AGP 8.7.3,
Gradle 8.11.1).*

## Goal and motivation

The workspace is Maven end-to-end — six modules under `ibparent`, one aggregator, one
`mvn verify` — except for the Android app, whose first build downloads the Gradle
distribution (~130 MB) and its entire dependency graph. The desire: make the Android
build answer to Maven like everything else, and stop paying the Gradle download.
Whatever the engine, `just android-build` / `just mobile-build` remain the executor
surface — recipes change targets, users don't change habits.

## What the Gradle build actually does (what Maven would have to replace)

| Pipeline step | Provided today by |
|---|---|
| Manifest merge (app + library manifests) | AGP |
| Resource compile + link, `R` class generation | AGP → AAPT2 |
| Kotlin compilation **with the Compose compiler plugin** | Kotlin Gradle plugin + `org.jetbrains.kotlin.plugin.compose` |
| Dexing (classes → DEX) | AGP → D8 (R8 for release shrinking) |
| APK packaging, alignment, debug signing | AGP → zipflinger, zipalign, apksigner |
| Dependency resolution (AARs — a Gradle-native packaging) | Gradle metadata + AGP AAR handling |
| Lint, unit/instrumented test orchestration | AGP |

## Hard constraints (the honest part)

1. **Google supports exactly one Android build system: AGP on Gradle.** Every SDK,
   Kotlin, and Compose release is validated against it and nothing else.
2. **The old `android-maven-plugin` is dead** (last meaningful release ~2016 —
   pre-AAPT2, pre-D8, no Kotlin, no Compose, no modern SDK). There is no maintained
   Maven plugin for Android application packaging.
3. **Compose is the hard blocker.** The Compose compiler is a Kotlin *compiler
   plugin* distributed through the Gradle plugin mechanism; `kotlin-maven-plugin`
   has no supported configuration for it. A pure-Maven build therefore realistically
   means **dropping Compose for Views/XML** — reversing the stack decision recorded
   in PLAN.md on 2026-08-09 — or maintaining an unsupported compiler-plugin wiring
   that may break on any Kotlin release.
4. **AARs are Gradle-native.** Maven can download them, but unpacking classes.jar,
   merging resources/manifests, and honoring consumer ProGuard rules is AGP work
   that would need hand reimplementation.
5. What makes a hand-rolled build *possible at all*: `aapt2`, `d8`, `apksigner`, and
   `zipalign` are standalone binaries in `build-tools;35.0.0`, driveable from
   `exec-maven-plugin`.
6. **Android Studio degrades without Gradle** — its project model imports Gradle
   builds; a Maven Android project loses most IDE integration.
7. Perspective on the pain being solved: the Gradle download is **once per machine**
   (distribution + dependencies cache in `~/.gradle`); subsequent builds are
   offline-capable. Today's rebuild proof: 2m13s first build, ~1s warm.

## Approach A — Maven orchestration wrapper *(recommended now)*

Make Maven the **orchestrator** while Gradle remains the engine — the same pattern as
`quarkus.native.container-build` delegating to a container.

1. New `pom.xml` in `inventory-mobile-apps/inventory-android-app` (packaging `pom`,
   parent `inventory-parent`): `exec-maven-plugin` bound to `package` running
   `./gradlew --no-daemon build`; `maven-clean-plugin` extended to run
   `./gradlew clean` (or delete `app/build`).
2. Root aggregator gains the module **behind a non-default profile** `-Pmobile`
   (the Android SDK isn't universally present; CI's Linux lane can opt in later,
   macOS-only iOS never joins the reactor).
3. Justfile: `android-build` gains nothing (still calls gradlew directly — fastest
   path); optionally a `verify-all` recipe noting `mvn -B verify -Pmobile`.

Outcome: `mvn verify -Pmobile` builds the whole workspace including the APK; one
command, one report. Effort: **hours**. Loses: nothing. Does not eliminate Gradle —
it domesticates it.

## Approach B — true pure-Maven build (what it actually takes)

Recorded so the cost is never underestimated; **not recommended**.

Precondition: **abandon Compose** (constraint 3) — migrate `MainActivity` to
Views/XML first. Then, all via `exec-maven-plugin` + `kotlin-maven-plugin` bindings:

1. `generate-resources`: `aapt2 compile` app resources; `aapt2 link` against
   `platforms/android-35/android.jar` → `resources.arsc` + generated `R.java` into
   `target/generated-sources` (add via `build-helper-maven-plugin`).
2. `process-classes` inputs: unpack every AAR dependency (classes.jar to the
   compile classpath, resources into the aapt2 link, manifests into a hand-rolled
   manifest merge — the fragile heart of the whole scheme).
3. `compile`: `kotlin-maven-plugin` (jvmTarget 17) + `javac` for `R.java`.
4. `prepare-package`: `d8` over app classes + all dependency jars → `classes.dex`
   (debug); R8 config becomes hand-maintained for any release build.
5. `package`: assemble APK zip (resources.arsc + dex + manifest + res/), `zipalign`,
   `apksigner sign` with a generated debug keystore.
6. SDK discovery: reimplement `local.properties`/`ANDROID_HOME` resolution in the
   pom (profiles + `properties-maven-plugin`).

Costs: 1–2 weeks to first working APK; permanent ownership of an unsupported
pipeline Google may break at every SDK/build-tools release; loss of lint, test
orchestration, install/run tasks, and Studio integration; and the Compose reversal.
Execute only on an explicit, PLAN.md-recorded decision that pure Maven is worth more
than Compose and vendor support.

## Approach C — kill the download without changing engines *(complements A)*

Attack the stated pain directly:

1. Devcontainer image gains Gradle 8.11.1 (matching the wrapper — the wrapper skips
   its distribution download when the exact version is present via
   `GRADLE_USER_HOME` priming) and the Android commandline-tools + platform 35 +
   build-tools 35.0.0 (mirroring what `MOBILE-READINESS.md` records for the host).
2. Prime the dependency cache at image build: run `./gradlew --no-daemon
   dependencies` (or a throwaway skeleton build) during `docker build`, so
   `~/.gradle/caches` ships in the image; CI builds run `--offline`.
3. Locally the cache lives in the bind-mounted home pattern already used for `~/.m2`.

Outcome: zero Gradle downloads in CI and fresh devcontainers. Effort: **small**.
This is the piece that actually deletes "the gradle download" from daily life.

## Recommendation

**A + C now; B never — unless dropping Compose is deliberately chosen** (if that day
comes, record the reversal in PLAN.md's decision table first, then execute B from
this document). A gives Maven-shaped orchestration; C deletes the download; together
they cost a day and forfeit nothing.

## Verification (when executed)

- **A**: `mvn -B verify -Pmobile` from the workspace root ends with the reactor
  green and `app/build/outputs/apk/debug/app-debug.apk` present; plain
  `mvn -B verify` (no profile) is unchanged; `just android-build` and
  `just mobile-build` still pass.
- **C**: building the devcontainer image twice, then running `just android-build`
  inside it with networking blocked (`--offline`) succeeds with zero downloads.
- **B** (only if ever executed): `mvn package` with no Gradle invocation anywhere
  produces an APK that installs (`adb install`) and launches on an emulator; CI
  proves it on a machine with no `~/.gradle` at all.

## Out of scope

- iOS: no Maven angle exists or is sought — `xcodebuild` via `just ios-build` stays.
- No changes to the Justfile-as-executor convention; recipes reroute if/when A lands.
