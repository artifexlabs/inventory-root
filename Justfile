# Inventory workspace task runner. RUNBOOK.md is the narrative; this file is
# the executor of record — run tasks from here so they stay verified.
# `just` with no arguments lists every task.

# --- toolchain gate ----------------------------------------------------------
# Requires just >= 1.58 (what the workspace and devcontainer install). Future
# upgrades are fine; raise this floor when a newer feature is adopted.

_version_gate := if semver_matches(just_version(), ">=1.58.0") == "true" { "ok" } else { error("this Justfile requires just >= 1.58.0, found " + just_version()) }

set shell := ["bash", "-euo", "pipefail", "-c"]
set dotenv-load := true

# --- configuration (override via environment or .env) ------------------------

# migrate_to_vertx_eb: inventory-web-api is the authenticated HTTP gateway
# (the only API entrypoint); the domain work happens in inventory-server's
# bus workers. server_url stays an alias so smoke/drill recipes read naturally.
server_url := env('INVENTORY_SERVER_URL', 'http://localhost:8081')
webapi_url := env('INVENTORY_WEB_API_URL', 'http://localhost:8081')
webapp_url := env('INVENTORY_WEBAPP_URL', 'http://localhost:8082')
admin_email := env('INVENTORY_ADMIN_EMAIL', 'admin@example.com')
admin_password := env('INVENTORY_ADMIN_PASSWORD', 'change-me')
pg_password := env('POSTGRES_PASSWORD', 'inventory')

# maven.test.skip (not skipTests): ibparent-root hard-pins <skipTests>false</skipTests>
# in its surefire config, so -DskipTests is silently ignored.
native_flags := "-Dmaven.test.skip=true -Dnative -Dquarkus.native.container-build=true"

ios_app_dir := "inventory-mobile-apps/inventory-ios-app"
android_app_dir := "inventory-mobile-apps/inventory-android-app"
ios_scheme := env('INVENTORY_IOS_SCHEME', 'InventoryApp')
ios_simulator := env('INVENTORY_IOS_SIMULATOR', 'iPhone 17')

# Compose files live in deploy/; --project-directory keeps their relative
# paths (build contexts, changelog mount), the root .env, and the project
# name resolving from the workspace root exactly as before the move.
compose := "docker compose --project-directory . -f deploy/docker-compose.yml"

# The extracted library repos (PLAN.md Phase 19), built IN THIS ORDER before
# the reactor: api -> impl -> bom. They are workspace submodules (artifexlabs-org
# repos) but deliberately NOT reactor modules — they install to ~/.m2 and the
# apps consume them as jars. inventory-parent is NOT here anymore: released
# as `1` (2026-08-21), it resolves from Central like artifex-maven-parent —
# re-add it temporarily only while developing the NEXT parent release.
lib_dirs := "inventory-api inventory-impl-root inventory-bom"

# EVERY recipe that runs Maven tests must go through this.
#
# dotenv-load exports the workspace .env, which is what the STACK recipes want
# — but unit tests assert UNCONFIGURED defaults, so that same .env breaks them:
#   * OidcExchangeDisabledTest expects the exchange absent; an inherited
#     exchange secret configures it (404 becomes 401).
#   * QrAndLabelTest expects the default LOG printer, including that `feed`
#     extends tape; .env points INVENTORY_PRINTER at real hardware, and a
#     ZebraPrinter correctly refuses to feed die-cut media (202 becomes 503).
# NOTE -DskipTests is NOT an escape: ibparent-root hard-pins
# <skipTests>false</skipTests>, so tests run anyway — only
# -Dmaven.test.skip=true genuinely skips them.
test_env := "env -u QUARKUS_OIDC_CLIENT_ID -u QUARKUS_OIDC_CREDENTIALS_SECRET -u INVENTORY_OIDC_EXCHANGE_SECRET -u INVENTORY_PRINTER -u INVENTORY_PRINTER_HOST -u INVENTORY_PRINTER_PORT -u INVENTORY_PRINTER_TAPE_MM -u INVENTORY_PRINTER_FORMAT"

# List every task.
default:
    @just --list --unsorted

# --- build -------------------------------------------------------------------

# Scope is deliberately the aggregator's four app modules. `mvn clean` only
# visits reactor modules, so the lib submodules stay untouched (use
# `clean-libs` for those; the flattened-pom sweep below does cover them,
# which is safe — stale flattened poms must never survive anywhere).
# artifex-parent is NEVER touched here.
# Deliberately NOT removed: src/main/web/node_modules (a dependency cache the
# island build reuses) and Xcode DerivedData (outside the repo).
#
# Remove build output from every module in this workspace.
[group('build')]
clean:
    @echo "-> delegating to Maven: mvn -B clean (the four workspace app modules)"
    mvn -B -ntp clean
    # flatten's own clean goal handles these, but sweep any left by an
    # interrupted build so a stale literal version can never be installed
    @find . -mindepth 2 -maxdepth 2 -name '.flattened-pom.xml' -print -delete || true
    @echo "clean: workspace modules only — peer lib repos untouched (use clean-libs)"

# Remove build output from the three lib submodules (NOT artifex-parent).
[group('build')]
clean-libs:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in {{ lib_dirs }}; do
      echo "-> delegating to Maven: mvn -B clean in $d"
      mvn -B -ntp -f "$d/pom.xml" clean
    done
    echo "clean-libs: {{ lib_dirs }} cleaned — ../artifex-parent untouched"

# Build + test + install the lib repos IN ORDER: parent -> api -> impl.
# Everything downstream resolves them from ~/.m2, so this must run before
# the reactor whenever a lib changed.
[group('build')]
libs:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in {{ lib_dirs }}; do
      echo "-> delegating to Maven: mvn -B clean install in $d (with tests)"
      {{ test_env }} mvn -B -ntp -f "$d/pom.xml" clean install
    done
    just _invalidate-quarkus-model-cache

# Quarkus serializes each app's test ApplicationModel to
# target/quarkus/bootstrap/*.dat and trusts it on the next run. Reinstalling
# the lib jars invalidates what those models recorded (dependency flags like
# is-this-jar-an-indexed-archive), and stale models then fail test bootstrap
# with misleading errors (ArC "not found in index", JUnit ClassSelector
# "Could not load class") in whichever app module cached one. Sweep them
# whenever the libs are rebuilt.
_invalidate-quarkus-model-cache:
    @find . -type f -path '*/target/quarkus/bootstrap/*.dat' -print -delete || true

# Build + JVM-test everything: the lib repos in order, then the app reactor.
# ALWAYS clean: VS Code's Eclipse-JDT compiler writes .class files into
# target/classes even when sources DON'T compile (it bakes "Unresolved
# compilation problem" stubs in, erasing unresolvable types), and Maven's
# incremental compile then trusts them — the source of a whole family of
# phantom test-bootstrap failures (ArC "not found in index", JUnit
# "Could not load class", Qute missing templates). Clean compiles are the
# only defense while the workspace is open in an IDE.
[group('build')]
verify: libs
    @echo "-> delegating to Maven: mvn -B clean verify (the four app modules, JVM tests)"
    {{ test_env }} mvn -B clean verify

# Native executable for one module, compiled in the Linux builder container.
[group('build')]
native module: _sync-libs
    @echo "-> delegating to Maven: native build of {{ module }} ({{ native_flags }})"
    mvn -pl {{ module }} -am clean package {{ native_flags }}

# JVM fast-jars for the bus members (gateway, server, projector): the
# vertx-infinispan cluster manager is not yet proven under GraalVM native,
# so cluster members ship as JVM containers.
[group('build')]
fastjars: _sync-libs
    @echo "-> delegating to Maven: fast-jars for the bus members"
    {{ test_env }} mvn -pl inventory-server,inventory-web-api,inventory-projector -am clean package -DskipTests

# Native executables (web-app only in the deployed stack).
[group('build')]
natives: (native "inventory-web-app")

# Container images from the built artifacts.
[group('build')]
images:
    {{ compose }} build

# Everything: fast-jars + natives, then images.
[group('build')]
build-all: fastjars natives images

# --- submodules --------------------------------------------------------------
# Nine repos hang off this superproject, and the pointer it RECORDS for each
# is independent of what is CHECKED OUT. These three recipes move between
# those two states; picking the wrong direction is how work gets lost, so
# each says exactly what it will do first.

# Record every submodule's CURRENT checkout as the superproject's pointer.
[group('submodules')]
subs-pin:
    #!/usr/bin/env bash
    set -euo pipefail
    moved=$(git submodule status | grep '^+' | awk '{ print $2 }' || true)
    if [ -z "$moved" ]; then
      echo "every submodule already matches its recorded pointer — nothing to pin"
      exit 0
    fi
    # A pointer to an UNPUSHED commit is the classic broken superproject: it
    # clones and it builds here, and CI cannot fetch the commit at all.
    unpushed=""
    for m in $moved; do
      ahead=$(git -C "$m" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo "?")
      echo "  $m -> $(git -C "$m" rev-parse --short HEAD) ($(git -C "$m" rev-parse --abbrev-ref HEAD), $ahead ahead of upstream)"
      [ "$ahead" != "0" ] && unpushed="$unpushed $m"
    done
    git add -- $moved
    echo "staged. NOT committed — write the message yourself."
    if [ -n "$unpushed" ]; then
      echo
      echo "WARNING: these are ahead of their upstream:$unpushed"
      echo "  push them BEFORE the superproject, or CI gets a pointer it cannot fetch."
    fi

# Check every submodule out at the pointer the superproject records.
[group('submodules')]
[confirm("This moves every submodule to its RECORDED commit, abandoning local checkouts. Continue? (y/N)")]
subs-restore:
    #!/usr/bin/env bash
    set -euo pipefail
    dirty=$(git submodule --quiet foreach 'test -z "$(git status --porcelain)" || echo $sm_path' || true)
    if [ -n "$dirty" ]; then
      echo "FAIL: uncommitted changes in:$(echo $dirty | tr '\n' ' ')"
      echo "commit or stash them first — this recipe will not discard your work"
      exit 1
    fi
    git submodule update --init --recursive
    echo "every submodule now sits at the commit this superproject records"

# Fast-forward every submodule to its REMOTE branch tip.
[group('submodules')]
[confirm("This moves every submodule to its remote tip, which can orphan unpushed local commits. Continue? (y/N)")]
subs-latest:
    #!/usr/bin/env bash
    set -euo pipefail
    dirty=$(git submodule --quiet foreach 'test -z "$(git status --porcelain)" || echo $sm_path' || true)
    if [ -n "$dirty" ]; then
      echo "FAIL: uncommitted changes in:$(echo $dirty | tr '\n' ' ')"
      exit 1
    fi
    # unpushed commits would be orphaned by the move — refuse rather than lose
    for m in $(git submodule --quiet foreach 'echo $sm_path'); do
      ahead=$(git -C "$m" rev-list --count '@{upstream}..HEAD' 2>/dev/null || echo 0)
      if [ "$ahead" != "0" ]; then
        echo "FAIL: $m has $ahead unpushed commit(s) — push them or they are orphaned by this move"
        exit 1
      fi
    done
    git submodule update --remote --recursive
    echo "every submodule now sits at its remote branch tip"
    echo "the superproject still records the OLD pointers — run 'just subs-pin' to adopt these"

# --- dev (live-coding; one terminal per tier) --------------------------------

# Fast lib install (no tests) — the dev/packaging prerequisite: everything in
# this reactor resolves inventory-parent/api/impl from ~/.m2. Use `just libs`
# for the tested variant. NOTE -Dmaven.test.skip=true, not -DskipTests, which
# ibparent hard-pins off.
_sync-libs:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in {{ lib_dirs }}; do
      echo "-> delegating to Maven: mvn -B clean install in $d (tests skipped)"
      {{ test_env }} mvn -q -B -ntp -f "$d/pom.xml" clean install -Dmaven.test.skip=true
    done
    just _invalidate-quarkus-model-cache

# inventory-web-api in live-coding mode on :8081 (embedded bus workers on the
# local bus — the full envelope path in one process; memory storage).
[group('dev')]
dev-web-api: _sync-libs
    @echo "-> delegating to Maven: quarkus:dev inventory-web-api (http://localhost:8081, embedded workers)"
    mvn -pl inventory-web-api quarkus:dev

# inventory-server in live-coding mode (bus worker host; pair with a
# remote-mode gateway for two-process dev — see DEPLOYMENT.md). Health moves
# to :8084 here so dev-webapp keeps :8082.
[group('dev')]
dev-server: _sync-libs
    @echo "-> delegating to Maven: quarkus:dev inventory-server (bus workers; health on :8084)"
    mvn -pl inventory-server quarkus:dev -Dquarkus.http.port=8084

# inventory-web-app in live-coding mode on :8082 (the browser entrypoint).
[group('dev')]
dev-webapp: _sync-libs
    @echo "-> delegating to Maven: quarkus:dev inventory-web-app (http://localhost:8082 — log in there)"
    mvn -pl inventory-web-app quarkus:dev

# --- stack -------------------------------------------------------------------

# Start the stack: postgres -> liquibase migrate (exits 0) -> the three apps.
[group('stack')]
up:
    {{ compose }} up -d
    @just ps

# Service status (migrate correctly shows Exited (0)).
[group('stack')]
ps:
    {{ compose }} ps -a --format 'table {{{{.Service}}\t{{{{.State}}\t{{{{.Status}}'

# Follow logs; `just logs inventory-web-api` for one service.
[group('stack')]
logs service="":
    {{ compose }} logs -f {{ service }}

# Stop the stack, KEEP the database volume.
[group('stack')]
down:
    {{ compose }} down

# Stop the stack and DESTROY the database volume.
[group('stack')]
[confirm("This DESTROYS the database volume. Continue? (y/N)")]
destroy:
    {{ compose }} down -v

# --- smoke (the standing check) ----------------------------------------------

# Login -> CRUD -> qr.png is a real PNG -> print-label 202 -> BFF view.
[group('smoke')]
smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "-> smoke against {{ server_url }} (server) and {{ webapi_url }} (web-api)"
    TOKEN=$(curl -s -X POST {{ server_url }}/api/v1/auth/login \
      -H 'Content-Type: application/json' \
      -d '{"email":"{{ admin_email }}","password":"{{ admin_password }}"}' \
      | sed -E 's/.*"token":"([^"]+)".*/\1/')
    [ -n "$TOKEN" ] && [ ${#TOKEN} -eq 26 ] || { echo "FAIL: login did not yield a token"; exit 1; }
    echo "ok: login (token acquired)"
    curl -sf -H "Authorization: Bearer $TOKEN" {{ server_url }}/api/v1/items > /dev/null
    echo "ok: items list"
    ID=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"name":"smoke-item","type":"tool"}' {{ server_url }}/api/v1/items \
      | sed -E 's/.*"id":"([^"]+)".*/\1/')
    echo "ok: created item $ID"
    curl -sf -H "Authorization: Bearer $TOKEN" {{ server_url }}/api/v1/items/$ID/qr.png -o /tmp/inventory-smoke-qr.png
    file /tmp/inventory-smoke-qr.png | grep -q 'PNG image data' || { echo "FAIL: qr.png is not a PNG"; exit 1; }
    echo "ok: qr.png is a real PNG (/tmp/inventory-smoke-qr.png; decode gate: it must encode <qr-base-url>/i/$ID)"
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" {{ server_url }}/api/v1/items/$ID/print-label)
    [ "$CODE" = "202" ] || { echo "FAIL: print-label returned $CODE"; exit 1; }
    echo "ok: print-label 202 accepted (queued to the printer verticle + audited)"
    curl -sf -H "Authorization: Bearer $TOKEN" "{{ webapi_url }}/api/v1/views/items?query=smoke" | grep -q smoke-item \
      || { echo "FAIL: BFF view missing smoke-item"; exit 1; }
    echo "ok: BFF view answers through web-api"
    echo "SMOKE PASS"

# End-to-end label smoke WITHOUT hardware: native stack + fake-printer TCP sink,
# asserting real Brother raster bytes (invalidate + ESC@ ... 0x1A) arrive.
[group('smoke')]
smoke-fake-printer:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "-> stack up with the fake printer (server pointed at it, not the real P750W)"
    INVENTORY_PRINTER=brother-p750w INVENTORY_PRINTER_HOST=fake-printer \
      {{ compose }} --profile fake-printer up -d
    just _wait-ready
    TOKEN=$(curl -s -X POST {{ server_url }}/api/v1/auth/login \
      -H 'Content-Type: application/json' \
      -d '{"email":"{{ admin_email }}","password":"{{ admin_password }}"}' \
      | sed -E 's/.*"token":"([^"]+)".*/\1/')
    ID=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
      -d '{"name":"fake-printer-smoke","type":"tool"}' {{ server_url }}/api/v1/items \
      | sed -E 's/.*"id":"([^"]+)".*/\1/')
    CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $TOKEN" \
      {{ server_url }}/api/v1/items/$ID/print-label)
    [ "$CODE" = "202" ] || { echo "FAIL: print-label returned $CODE"; exit 1; }
    echo "ok: print-label 202 accepted against the fake printer"
    # acceptance is not completion: the raster lands a moment later
    sleep 4
    JOB=$({{ compose }} --profile fake-printer exec -T fake-printer sh -c 'ls -t /jobs 2>/dev/null | head -1')
    [ -n "$JOB" ] || { echo "FAIL: no job captured by the fake printer"; exit 1; }
    {{ compose }} --profile fake-printer cp fake-printer:/jobs/$JOB /tmp/inventory-fake-printer-job.bin
    python3 - <<'PY'
    data = open('/tmp/inventory-fake-printer-job.bin', 'rb').read()
    assert len(data) > 102, f"job too short: {len(data)} bytes"
    assert data[:100] == bytes(100), "missing 100-byte invalidate preamble"
    assert data[100:102] == b'\x1b\x40', "missing ESC @ initialize"
    assert data[-1] == 0x1A, "missing print command terminator"
    print(f"ok: raster job verified ({len(data)} bytes, preamble + ESC@ ... 0x1A)")
    PY
    echo "FAKE-PRINTER SMOKE PASS (end-to-end raster bytes, no hardware)"

# POST print-label for an existing item id (hardware gate: scan the physical label).
[group('smoke')]
print-label id:
    #!/usr/bin/env bash
    set -euo pipefail
    TOKEN=$(curl -s -X POST {{ server_url }}/api/v1/auth/login \
      -H 'Content-Type: application/json' \
      -d '{"email":"{{ admin_email }}","password":"{{ admin_password }}"}' \
      | sed -E 's/.*"token":"([^"]+)".*/\1/')
    curl -s -o /dev/null -w 'print-label -> %{http_code}\n' -X POST \
      -H "Authorization: Bearer $TOKEN" {{ server_url }}/api/v1/items/{{ id }}/print-label
    echo "reminder: hardware printing needs INVENTORY_PRINTER=brother-p750w and INVENTORY_PRINTER_HOST on the server"

# --- restart drills ----------------------------------------------------------

# Warm: bounce the server process; data must survive.
[group('drill')]
drill-warm:
    {{ compose }} restart inventory-web-api
    @just _wait-ready
    @just smoke

# Cold: full stack down and up, volume kept; migrate re-runs idempotently.
[group('drill')]
drill-cold:
    {{ compose }} down
    {{ compose }} up -d
    @just _wait-ready
    @just smoke

# From empty: destroy the volume, rebuild schema from nothing.
[group('drill')]
[confirm("This DESTROYS the database volume before the drill. Continue? (y/N)")]
drill-empty:
    {{ compose }} down -v
    {{ compose }} up -d
    @just _wait-ready
    @just smoke

_wait-ready:
    #!/usr/bin/env bash
    set -euo pipefail
    echo -n "waiting for {{ server_url }} "
    for i in $(seq 1 60); do
      CODE=$(curl -s -o /dev/null -w '%{http_code}' -X POST {{ server_url }}/api/v1/auth/login \
        -H 'Content-Type: application/json' \
        -d '{"email":"{{ admin_email }}","password":"{{ admin_password }}"}' || true)
      [ "$CODE" = "200" ] && { echo " ready"; exit 0; }
      echo -n "."; sleep 1
    done
    echo " FAIL: server not ready after 60s"; exit 1

# --- mobile (Phase 12: iOS universal app; macOS-only, not Maven) --------------

# Debug build of the iOS app for the simulator (unsigned; delegates to xcodebuild).
[group('mobile')]
[macos]
ios-build: _ios-preflight
    @echo "-> delegating to xcodebuild: Debug simulator build of {{ ios_scheme }} (CODE_SIGNING_ALLOWED=NO)"
    cd {{ ios_app_dir }} && xcodebuild -scheme {{ ios_scheme }} \
      -destination 'generic/platform=iOS Simulator' -configuration Debug \
      CODE_SIGNING_ALLOWED=NO build

# Run the iOS app's tests on a simulator (delegates to xcodebuild test).
[group('mobile')]
[macos]
ios-test: _ios-preflight
    @echo "-> delegating to xcodebuild: tests of {{ ios_scheme }} on '{{ ios_simulator }}'"
    cd {{ ios_app_dir }} && xcodebuild -scheme {{ ios_scheme }} \
      -destination 'platform=iOS Simulator,name={{ ios_simulator }}' \
      CODE_SIGNING_ALLOWED=NO test

# Open the iOS app in Xcode.
[group('mobile')]
[macos]
ios-open: _ios-preflight
    open {{ ios_app_dir }}/*.xcodeproj 2>/dev/null || open {{ ios_app_dir }}/*.xcworkspace

# Regenerate InventoryApp.xcodeproj from project.yml (XcodeGen is the source of truth).
[group('mobile')]
[macos]
ios-regen:
    @echo "-> delegating to XcodeGen: regenerating {{ ios_app_dir }}/InventoryApp.xcodeproj"
    cd {{ ios_app_dir }} && xcodegen generate

# Build the Android app (Kotlin + Compose; delegates to the Gradle wrapper).
[group('mobile')]
android-build:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -x "{{ android_app_dir }}/gradlew" ]; then
      echo "-> delegating to Gradle: {{ android_app_dir }}/gradlew build"
      cd {{ android_app_dir }} && ./gradlew build
    else
      echo "NOTE: no Gradle wrapper in {{ android_app_dir }} — Android app not yet scaffolded (placeholder repo); nothing to build"
    fi

# Build ALL mobile apps (iOS + Android).
[group('mobile')]
[macos]
mobile-build: ios-build android-build

[macos]
_ios-preflight:
    #!/usr/bin/env bash
    set -euo pipefail
    xcodebuild -version > /dev/null 2>&1 \
      || { echo "FAIL: full Xcode required (only Command Line Tools found) — see MOBILE-READINESS.md"; exit 1; }
    compgen -G "{{ ios_app_dir }}/*.xcodeproj" > /dev/null || compgen -G "{{ ios_app_dir }}/*.xcworkspace" > /dev/null \
      || { echo "FAIL: no Xcode project in {{ ios_app_dir }} — Phase 12 (initial iOS app) not yet executed"; exit 1; }

# --- backup / restore / migrations (day-2) -----------------------------------

# pg_dump the running database (custom format).
[group('day2')]
backup file=("inventory-" + datetime("%F") + ".dump"):
    {{ compose }} exec postgres pg_dump -U inventory -Fc inventory > {{ file }}
    @echo "backup written: {{ file }}"

# Restore a dump into a FRESH volume, then start the stack.
[group('day2')]
[confirm("This DESTROYS the current database volume before restoring. Continue? (y/N)")]
restore file:
    {{ compose }} down -v
    {{ compose }} up -d postgres
    sleep 5
    {{ compose }} exec -T postgres pg_restore -U inventory -d inventory --clean --if-exists < {{ file }}
    {{ compose }} up -d
    @just ps

# Apply pending Liquibase changesets (idempotent; also runs on every `just up`).
# --build refreshes the inventory-migrate image from the changeset jar; a NEW
# changeset therefore needs `just libs` (rebuild the jar) before this.
[group('day2')]
migrate:
    {{ compose }} run --rm --build migrate

# Roll back the last N changesets.
[group('day2')]
[confirm("Rolling back applied changesets. Continue? (y/N)")]
rollback count="1":
    {{ compose }} run --rm --build migrate \
      --url=jdbc:postgresql://postgres:5432/inventory \
      --username=inventory --password={{ pg_password }} \
      --changelog-file=db/changelog-master.yaml \
      rollback-count {{ count }}

# --- release (Phase 14 flow: tag-driven images to public Docker Hub) ----------

# Show what `just release <version>` would do — checks only, no verify, no tags.
[group('release')]
release-plan version:
    @just _release-checks {{ version }}
    @echo "release plan for v{{ version }}:"
    @echo "  1. full reactor verify at -Drevision={{ version }}"
    @echo "  2. annotated tag v{{ version }} on the superproject (HEAD)"
    @git submodule status | awk '{ sub(/^[+-]?/, "", $1); printf "  3. tag v{{ version }} in %s at recorded %s\n", $2, substr($1, 1, 12) }'
    @echo "  4. NOTHING pushes. Pushing the superproject tag triggers release.yml,"
    @echo "     which publishes PUBLIC images to docker.io/artifexlabs/{inventory-server,inventory-web-api,inventory-projector,inventory-web-app}:{{ version }}"

# Cut a release LOCALLY: verify the reactor at the release version, then tag
# the superproject and mirror the tag into every submodule at its recorded
# SHA. Nothing is pushed — the recipe ends by printing exactly what to push.
[group('release')]
release version:
    @just _release-checks {{ version }}
    @just libs
    @echo "-> delegating to Maven: app-reactor verify at -Drevision={{ version }} (libs keep their own literal versions)"
    env -u QUARKUS_OIDC_CLIENT_ID -u QUARKUS_OIDC_CREDENTIALS_SECRET -u INVENTORY_OIDC_EXCHANGE_SECRET \
      mvn -B verify -Drevision={{ version }}
    @just _release-tags {{ version }}

# Preconditions: clean tree, on develop/master, tag not already taken anywhere.
_release-checks version:
    #!/usr/bin/env bash
    set -euo pipefail
    [[ "{{ version }}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.].+)?$ ]] \
      || { echo "FAIL: '{{ version }}' is not a semver version (expected X.Y.Z, no leading v)"; exit 1; }
    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    [[ "$BRANCH" == "develop" || "$BRANCH" == "master" ]] \
      || { echo "FAIL: releases cut from develop or master only (on '$BRANCH')"; exit 1; }
    [ -z "$(git status --porcelain)" ] \
      || { echo "FAIL: working tree is dirty (submodule pointers count)"; git status --short; exit 1; }
    git submodule status | grep -q '^[+-]' \
      && { echo "FAIL: a submodule checkout differs from the recorded SHA"; git submodule status | grep '^[+-]'; exit 1; }
    git rev-parse -q --verify "refs/tags/v{{ version }}" > /dev/null \
      && { echo "FAIL: tag v{{ version }} already exists in the superproject"; exit 1; }
    git submodule --quiet foreach 'git rev-parse -q --verify "refs/tags/v{{ version }}" > /dev/null && { echo "FAIL: tag v{{ version }} already exists in $name"; exit 1; } || true'
    echo "ok: preconditions clear for v{{ version }}"

# Tag the superproject at HEAD and each submodule at its RECORDED SHA (not its
# checkout), so the tags reproduce exactly what the superproject pins.
_release-tags version:
    #!/usr/bin/env bash
    set -euo pipefail
    git tag -a "v{{ version }}" -m "inventory release {{ version }}"
    echo "tagged superproject: v{{ version }} at $(git rev-parse --short HEAD)"
    git submodule --quiet foreach 'git tag -a "v{{ version }}" -m "inventory release {{ version }}" "$sha1" && echo "tagged $name: v{{ version }} at $sha1"'
    echo
    echo "release v{{ version }} is cut locally. To publish (house rule: only on your say):"
    echo "  git push origin v{{ version }}            # triggers release.yml -> PUBLIC Docker Hub images + draft release"
    echo "  git submodule foreach 'git push origin v{{ version }}'"
    echo "then verify the four artifexlabs/* repos on Docker Hub carry the new tag (RUNBOOK: 'Cutting a release')."

# --- library release train (PLAN.md Phase 19's per-release chore) -------------
#
# Releasing a cross-cutting change means five ordered steps: api, then the
# impl train pinned to it, then the BOM pinned to both, then the apps' BOM
# import. This is that sequence as recipes.
#
# It is deliberately NOT one command. central-publishing-maven-plugin runs
# with autoPublish=false, so each step only STAGES a bundle and a human
# publishes it in the Central portal before the next step can resolve it.
# A single `train` recipe would have to either lie about that or block on it.
#
# Releases run from a local machine ONLY (owner decision, 2026-08-21): CI
# verifies, never releases, so no signing key or credential leaves this
# machine and nothing automated can trigger an irreversible publish.

lib_repos := "inventory-api inventory-impl-root inventory-bom"
app_repos := "inventory-web-api inventory-web-app inventory-server inventory-projector"

# What the train would do: current pins, local versions, and preflight state.
[group('release-train')]
train-plan:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "library release train — current state"
    echo
    printf "  %-22s %-18s %s\n" REPO LOCAL-VERSION BRANCH
    for d in {{ lib_repos }}; do
      v=$(cd "$d" && mvn -q -N -o help:evaluate -Dexpression=project.version -DforceStdout 2>/dev/null | tail -1)
      printf "  %-22s %-18s %s\n" "$d" "$v" "$(git -C "$d" branch --show-current)"
    done
    echo
    echo "  pins:"
    printf "    impl-root -> api      %s\n" "$(just _prop inventory-impl-root inventory.api.version)"
    printf "    bom       -> api      %s\n" "$(just _prop inventory-bom inventory.api.version)"
    printf "    bom       -> impl     %s\n" "$(just _prop inventory-bom inventory.impl.version)"
    for d in {{ app_repos }}; do
      printf "    %-9s -> bom      %s\n" "$(echo $d | sed 's/inventory-//')" "$(just _prop "$d" inventory.bom.version)"
    done
    echo
    echo "  preflight:"
    if [ -n "${MAVEN_GPG_PASSPHRASE:-}" ]; then echo "    MAVEN_GPG_PASSPHRASE  set"
    else echo "    MAVEN_GPG_PASSPHRASE  NOT SET — signing will fail mid-train (see RUNBOOK: pinentry)"; fi
    for d in {{ lib_repos }} {{ app_repos }}; do
      [ -z "$(git -C "$d" status --porcelain)" ] || echo "    $d has uncommitted changes"
    done
    echo
    echo "  order: train-api X -> portal -> train-impl X X -> portal -> train-bom X X X -> portal -> train-apps X"

# Read one Maven property from a repo's effective pom.
_prop dir property:
    @cd {{ dir }} && mvn -q -N -o help:evaluate -Dexpression={{ property }} -DforceStdout 2>/dev/null | tail -1

# Step 1: release inventory-api.
[group('release-train')]
train-api version:
    @just _train-checks inventory-api {{ version }}
    cd inventory-api && mvn -B release:prepare release:perform \
      -DreleaseVersion={{ version }} -Dtag=v{{ version }} -DautoVersionSubmodules=true
    @just _portal-step inventory-api {{ version }} "train-impl {{ version }} <impl-version>"

# Step 2: pin the impl train to the released api, then release the train.
[group('release-train')]
train-impl api_version version:
    @just _train-checks inventory-impl-root {{ version }}
    cd inventory-impl-root && mvn -q versions:set-property -Dproperty=inventory.api.version \
      -DnewVersion={{ api_version }} -DgenerateBackupPoms=false && mvn -q tidy:pom
    @just _no-snapshot-pins inventory-impl-root
    cd inventory-impl-root && git commit -qam "Pin inventory-api {{ api_version }} for the {{ version }} release" || true
    just libs
    cd inventory-impl-root && mvn -B release:prepare release:perform \
      -DreleaseVersion={{ version }} -Dtag=v{{ version }} -DautoVersionSubmodules=true
    @just _portal-step inventory-impl-root {{ version }} "train-bom {{ api_version }} {{ version }} <bom-version>"

# Step 3: re-pin the BOM to both released libraries, then release it.
[group('release-train')]
train-bom api_version impl_version version:
    @just _train-checks inventory-bom {{ version }}
    cd inventory-bom && mvn -q versions:set-property -Dproperty=inventory.api.version \
      -DnewVersion={{ api_version }} -DgenerateBackupPoms=false \
      && mvn -q versions:set-property -Dproperty=inventory.impl.version \
      -DnewVersion={{ impl_version }} -DgenerateBackupPoms=false && mvn -q tidy:pom
    @just _no-snapshot-pins inventory-bom
    cd inventory-bom && git commit -qam "Pin api {{ api_version }} / impl {{ impl_version }} for the {{ version }} release" || true
    cd inventory-bom && mvn -B release:prepare release:perform \
      -DreleaseVersion={{ version }} -Dtag=v{{ version }}
    @just _portal-step inventory-bom {{ version }} "train-apps {{ version }}"

# Step 4: point the four apps at the released BOM and prove the whole set builds.
[group('release-train')]
train-apps bom_version:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in {{ app_repos }}; do
      [ -z "$(git -C "$d" status --porcelain)" ] || { echo "FAIL: $d is dirty"; exit 1; }
    done
    for d in {{ app_repos }}; do
      (cd "$d" && mvn -q versions:set-property -Dproperty=inventory.bom.version \
        -DnewVersion={{ bom_version }} -DgenerateBackupPoms=false && mvn -q tidy:pom)
      echo "pinned $d -> inventory-bom {{ bom_version }}"
    done
    # a clean verify, because only a build proves the combination coheres —
    # which is the entire reason the BOM exists
    just verify
    for d in {{ app_repos }}; do
      (cd "$d" && git commit -qam "Consume inventory-bom {{ bom_version }}")
    done
    echo
    echo "the apps now consume inventory-bom {{ bom_version }} and the reactor is green."
    echo "NOTHING pushed (house rule). When you are ready:"
    for d in {{ app_repos }}; do echo "  git -C $d push"; done
    echo "  git commit -am 'Consume inventory-bom {{ bom_version }}' && git push   # superproject pointers"

# Preconditions for a library release step.
_train-checks dir version:
    #!/usr/bin/env bash
    set -euo pipefail
    # checked FIRST: it is the one failure whose fix is outside the repo, and
    # the one that otherwise surfaces halfway through a signing run
    [ -n "${MAVEN_GPG_PASSPHRASE:-}" ] \
      || { echo "FAIL: MAVEN_GPG_PASSPHRASE is unset; signing will fail partway through the release"; exit 1; }
    [[ "{{ version }}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.].+)?$ ]] \
      || { echo "FAIL: '{{ version }}' is not a semver version"; exit 1; }
    [ -z "$(git -C {{ dir }} status --porcelain)" ] \
      || { echo "FAIL: {{ dir }} has uncommitted changes"; git -C {{ dir }} status --short; exit 1; }
    BRANCH=$(git -C {{ dir }} branch --show-current)
    [[ "$BRANCH" == "develop" || "$BRANCH" == "main" || "$BRANCH" == "master" ]] \
      || { echo "FAIL: release {{ dir }} from develop/main/master (on '$BRANCH')"; exit 1; }
    git -C {{ dir }} rev-parse -q --verify "refs/tags/v{{ version }}" > /dev/null \
      && { echo "FAIL: tag v{{ version }} already exists in {{ dir }}"; exit 1; } || true
    echo "ok: {{ dir }} ready to release {{ version }}"

# Central rejects a released pom whose dependencyManagement names a SNAPSHOT.
_no-snapshot-pins dir:
    #!/usr/bin/env bash
    set -euo pipefail
    if grep -n 'SNAPSHOT' {{ dir }}/pom.xml | grep -v '<version>.*SNAPSHOT</version>.*<!-- own' | grep -q 'inventory\.'; then
      echo "FAIL: {{ dir }}/pom.xml still pins an inventory SNAPSHOT — Central will reject the bundle"
      grep -n 'inventory\..*SNAPSHOT' {{ dir }}/pom.xml
      exit 1
    fi
    echo "ok: no inventory SNAPSHOT pins in {{ dir }}"

# The one manual step between train stages.
_portal-step dir version next:
    @echo
    @echo "{{ dir }} {{ version }} is STAGED, not published (autoPublish=false)."
    @echo "  1. open https://central.sonatype.com/publishing/deployments"
    @echo "  2. check the deployment, then Publish"
    @echo "  3. when it shows PUBLISHED, continue with: just {{ next }}"
    @echo
    @echo "nothing was pushed. To push this step's release commits and tag:"
    @echo "  git -C {{ dir }} push && git -C {{ dir }} push origin v{{ version }}"
