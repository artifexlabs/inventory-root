# TODO — the near-term list, in order

*One stop for what is outstanding and where each thing is described in
detail. Started 2026-08-29. PLAN.md remains the record; this file is the
queue. When an item lands, mark it here with the date and where it went.*

Ordering rule, stated by the owner: **nothing is persisted for real until
there is a good path to bootstrap, stand up, back up and restore, tear down,
and upgrade.** Item 1 is that path; everything that stores data waits behind
it.

## 1. Settle the deployment workflow — run it, break it, run it again

The whole day-2 story exercised end to end on the reference deployment, with
what breaks fixed as it breaks:

- **Bootstrap** from a clean machine: clone, `.env`, `just build-all`,
  `just up`, `just smoke`.
- **Tear down and stand up**: `just down` / `just up` keeps data; `just
  destroy` / `just up` rebuilds from nothing (`drill-cold`, `drill-empty`,
  `drill-warm` — RUNBOOK).
- **Backup and recovery**: `just backup` → `just destroy` → `just restore
  <file>` → `just smoke` passes and the data is back. (Today this is the
  `pg_dump` path — the Postgres accelerator Phase 24 keeps; the portable
  backup arrives with item 5.)
- **Day-2 upgrade**: a new build over a live database — `just migrate`
  idempotent, images swapped, data intact — and the rollback caveat proven,
  not read.
- Fix on the way: the two base-URL warts in item 2, and the Postgres
  reachability note for the hasher (a tunnel, or a published port on a
  trusted LAN).

Where: [deploy/DEPLOYMENT.md](deploy/DEPLOYMENT.md) (the method, the
configuration table, "The public base URL, and moving hosts");
[RUNBOOK.md](RUNBOOK.md) (day-2 operations, drills, backup/restore,
migrations). *Gate: every bullet above done on this machine, with the
commands that worked recorded in DEPLOYMENT.md where they differ from what is
written.*

## 2. The public base URL: name it honestly, default it correctly

`inventory.qr.base-url` becomes `inventory.public.base-url` (old name kept as
an alias); the code default stops pointing at the API port that does not
serve `/i/`; the move checklist is verified by actually moving a dev stack to
a second hostname and healing old QR codes with the one-line redirect. Owner's
requirement: this lands **before streaming ingest**.

Where: [deploy/DEPLOYMENT.md](deploy/DEPLOYMENT.md) "The public base URL, and
moving hosts". *Gate: a label printed under base A resolves in the iOS app
and, via the redirect, in a browser, after the stack answers only at base B.*

## 3. Streaming ingest — the step 0 three plans share

`DataSystem.replaceManifest` takes a stream and `DataTree` folds one; the
ingest routes stream the body to disk. The design risk is gone — the Python
fold ran 131.5M lines with zero depth-first violations and is proven
bit-identical to `MerkleHash` — so this is a port, gated at the real scale
(a 120M-entry manifest inside a bounded heap).

Where: [EXTERNAL_HASHING.md](EXTERNAL_HASHING.md) step 0 and D4;
[IMPORT_EXPORT.md](IMPORT_EXPORT.md) step 1 (restore needs it);
the reference fold at
`inventory-impl-root/inventory-impl-pg/src/test/resources/measurements/structure-analysis.py`;
PLAN.md Phase 23 "recorded, not adopted".

## 4. Catalog the real medium, end to end

Decide the medium root first — the **live tree** (a durable medium), not a
snapshot generation (the filesystem's own history; 13 of them, 1.4 PB
logical). Rename the handful of files with newlines in their names (297
broken manifest lines; the parser refuses the whole manifest at the first),
describe through item 3's streaming route, ask `GET …/data/sections` for the
answer over HTTP, then start `inventory-hasher hash` on the box and let the
content pass run. Revisit size-triage ordering if the wait proves annoying.

Where: [RUNBOOK.md](RUNBOOK.md) "Hashing a data medium";
`measurements/results/README.md` and `mediaX-structure-2026-08-29.txt` (what
the analysis already found: 81,513 duplicated sections, ~19.3 TB within one
generation); PLAN.md Phase 23. *Gate: the 19.3 TB answer comes from the
product over HTTP, and the first MERKLE-confirmed duplicate exists.*

## 5. Backup, export, and disaster recovery (Phase 24)

Confirm the decisions (D4 no DbUnit, D8 the restore surface, D10 the asset
archive, D11/D12 the native kind), then step 0: the restore surface in the
api, proven by the parity kit — the api break every later step depends on and
the one that gets dearer the longer features accumulate on the api.

Where: [IMPORT_EXPORT.md](IMPORT_EXPORT.md); PLAN.md Phase 24.

## 6. The remaining parity kits (Phase 20 step 0's tail)

Assets/regions, auth, audit. No external blockers; the kit has caught three
real bugs so far. Filler for whenever an item above is waiting on a build or a
hash run.

Where: PLAN.md Phase 20, step 0.

## 7. External scanning (Phase 25)

Confirm D1 (one tool, one language) and D6 (CI builds the five binaries),
then steps 1–4: the offline `scan` mode with a local journal, the resumable
upload processed as a job, the web-app downloads/upload pages, the CI build
matrix with checksums and cosign. Step 0 is item 3.

Where: [EXTERNAL_HASHING.md](EXTERNAL_HASHING.md); PLAN.md Phase 25.

## 8. The next release, when there is one

Not now (owner, 2026-08-28). When it comes, the order is forced by the
train's own guard: `artifex-maven-parent 3` → `inventory-parent 3` → repoint
every module from `3-SNAPSHOT` → `train-bom` / `train-apps` restore the
release pins → the 0.2.1 break train carries everything queued since 0.2.0.

Where: [RUNBOOK.md](RUNBOOK.md) "The library release train"; PLAN.md Phase 22
(the train) and Phase 19.

## 9. Label follow-ups (need the printer, and explicit go-ahead to print)

The x-large field expansion ("plenty of room for additional data") and the
`^LL812`-against-846-pitch drift check across a long run.

Where: PLAN.md ongoing item 14.

## 10. AI-assisted cataloging — a design conversation first

CLI-shaped, no per-transaction service. Nothing written yet beyond the idea.

Where: PLAN.md ongoing item 9.

## Waiting on things outside this repo

- **Apple Developer enrollment** (refused: "Action not allowed") — blocks
  Phase 13's paid-account tail, iOS NFC (item 12), and macOS notarization
  (Phase 25 D7; `curl` works meanwhile).
- **Android** — deferred by the owner; no device.
- **Phase 18 visual design** — waits on the owner's reference examples.
- **Hosting at a fixed domain** — deferred by the owner; item 2 makes the
  eventual move a checklist rather than a migration.
