# Mobile developer readiness — Phase 11 checklist

*(Renumbered from Phase 10 on 2026-08-08 when CI readiness took that slot.)*

*Created 2026-08-08. Goal: every credential and tool needed to START iOS/Android
development exists before the mobile milestone begins. Machine-verifiable items were
checked on the dev Mac on 2026-08-08 (re-run the command shown to re-verify). Account
items are human actions with a verification step. The mobile app STACK is deliberately
NOT chosen here — that remains an open unknown; nothing below forecloses any stack.*

## Accounts and credentials (human actions)

- [ ] **Apple ID selected** for development (decide personal vs. dedicated).
- [ ] **Apple Developer Program enrollment** — $99/year, https://developer.apple.com/enroll
      (individual is fine; org enrollment needs a D-U-N-S number and takes longer).
      Needed for: on-device install beyond 7-day free provisioning, TestFlight, App
      Store, push notifications, universal links.
      *Verify:* https://developer.apple.com/account shows an active membership; after
      Xcode install, Xcode → Settings → Accounts lists the team.
- [ ] **Google account selected** for development.
- [ ] **Google Play Console developer account** — $25 one-time,
      https://play.google.com/console/signup. Identity verification can take days —
      start early. Individual accounts created after Nov 2023 also need a closed test
      with 12+ testers for 14 days before production release — plan for it, not a
      blocker for development.
      *Verify:* Play Console dashboard loads with "All apps" and no outstanding
      verification banners.
- [ ] **Bundle/application id reserved** (at first app creation, both stores):
      suggest `io.artifexlabs.inventory.app`. No action possible until enrollments
      exist; record the chosen id here when taken.
- [ ] **Android upload keystore** generated and backed up somewhere durable
      (`keytool -genkeypair ...`), Play App Signing enrolled at first upload. Do NOT
      commit the keystore; record its location here.

## Local tooling (machine-verified)

- [x] **JDK 21** — present (`java -version` → openjdk 21.0.12, verified 2026-08-08).
- [x] **Apple Command Line Tools** — present (16.4, verified 2026-08-08 via
      `pkgutil --pkg-info=com.apple.pkg.CLTools_Executables`).
- [x] **Full Xcode** — INSTALLED 2026-08-09: Xcode 26.3 (17C529) via `.xip` from
      developer.apple.com (the App Store path failed twice on this machine: a wedged
      `installd`, then search hiding; the xip route is the reliable fallback —
      download, `xip -x`, move to /Applications, `sudo xcode-select -s`, license,
      `-runFirstLaunch`). *Verify:* `xcodebuild -version` → Xcode 26.3.
- [x] **iOS simulator runtime** — INSTALLED 2026-08-09: iOS 26.3.1 via
      `xcodebuild -downloadPlatform iOS` (modern Xcode ships without the iOS
      platform; no sudo needed). *Verify:* `xcrun simctl list runtimes` lists
      iOS 26.3. `just ios-build` compiles the skeleton app — verified green.
- [x] **Android SDK** — INSTALLED 2026-08-09 via `android-commandlinetools` (brew
      cask; no Studio needed for headless builds): platform-tools, platform 35,
      build-tools 35.0.0 at `/usr/local/share/android-commandlinetools`, licenses
      accepted, `local.properties` points the app at it. `just android-build`
      compiles the Kotlin+Compose skeleton — verified green. *(Android Studio
      itself remains optional/uninstalled — install it if/when IDE work wants it:
      `brew install --cask android-studio`.)*
- [ ] **Android emulator or physical device** boots and `adb devices` sees it
      (physical device: enable developer mode + USB debugging).
- [x] **Node.js LTS** — INSTALLED 2026-08-29 by the owner with a machine update:
      v26.8.1, npm 11.19.0 (`/usr/local/bin/node`). *Verify:* `node --version`.
      Note the stack decided 2026-08-09 (native SwiftUI, native Kotlin + Compose —
      PLAN.md open unknowns) never needed it for mobile; the web-app's Vite
      islands use the Node that `frontend-maven-plugin` downloads for itself, so
      a system Node is a convenience for hand-running the island toolchain, not
      a build input. The gate is closed either way.

## Deep-link wiring (deferred — depends on a public HTTPS domain, not credentials)

- [ ] iOS Universal Links: `apple-app-site-association` served from the deployed
      webapp domain (ties the QR `/i/{id}` links to the app). Needs the paid Apple
      account's team id + the chosen bundle id + a real domain.
- [ ] Android App Links: `/.well-known/assetlinks.json` on the same domain, signed
      with the upload key's cert fingerprint.

## Done when

Every box above except the two deferred deep-link items is checked. At that point
mobile development can start the same day the stack is chosen. *(Re-verified
2026-08-29 after a macOS 15.7.9 update: JDK 21.0.12, Xcode 26.3 / CLT 16.4, the
iOS 26.3 runtime, and Android platform 35 all still present; `adb devices` still
sees no device — the one local-tooling box left open, and the owner has said
Android waits.)*
