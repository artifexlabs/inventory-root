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
  backup arrives with item 6.)
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
requirement: this lands **before streaming ingest** (item 4).

Where: [deploy/DEPLOYMENT.md](deploy/DEPLOYMENT.md) "The public base URL, and
moving hosts". *Gate: a label printed under base A resolves in the iOS app
and, via the redirect, in a browser, after the stack answers only at base B.*

## 3. Virtual threads at the storage door — and the move to Java 25 that goes with it

The storage layer's complexity is 136 reactive chains, measured, not a Java
version. Inside the storage door — `StorageVerticle` and the `Pg*` backends —
code runs on virtual threads as sequential Java (a transaction is a block, a
loop is a loop), awaiting the same Mutiny pool; the api stays
`CompletionStage`, the bus stays asynchronous, and the parity kit is the gate
unchanged. It goes **before** streaming ingest because it makes ingest a
`for` loop inside a transaction instead of a `Publisher` threaded through a
reactive one.

**The Java 25 move is part of this item, not a separate one.** On Java 21 a
virtual thread that blocks inside `synchronized` pins its carrier (JEP 444);
JEP 491 removed that in Java 24, and two storage classes plus libraries
underneath use `synchronized`. So step 0 is the JDK: pin 25 in the parent
chain (`ibparent` → `artifex-maven-parent 3` → `inventory-parent 3`, the move
already in flight on `3-SNAPSHOT`), lift `quarkus.platform.version` from
`3.27.5.1` to a Java-25-capable line (~3.28+), GraalVM/Mandrel 25 for the
native builds, the CI runner JDK — then the threading model, then the ports.
`-Djdk.tracePinnedThreads` in the gate is what proves the pinning argument
rather than assumes it.

Where: PLAN.md Phase 26 (the decision, steps 0–4, the deadlock risk and the
semaphore). *Gate: `StorageVerticle` on `VIRTUAL_THREAD`, `storeScope` /
`replaceManifest` ported as the proof, `DataSystemTck` unchanged and green on
Pg, the 80k-entry manifest no slower than 14.0 s, `PgDataFactsTest` still
publishing after commit, no pinned threads reported from our code.*

## 4. Streaming ingest — the step 0 three plans share

`DataSystem.replaceManifest` takes a stream and `DataTree` folds one; the
ingest routes stream the body to disk. The design risk is gone — the Python
fold ran 131.5M lines with zero depth-first violations and is proven
bit-identical to `MerkleHash` — so this is a port, gated at the real scale
(a 120M-entry manifest inside a bounded heap). Written in item 3's style: a
loop over the stream inside one transaction block, the first feature built on
the door rather than ported through it (Phase 26 step 4).

Where: [EXTERNAL_HASHING.md](EXTERNAL_HASHING.md) step 0 and D4;
[IMPORT_EXPORT.md](IMPORT_EXPORT.md) step 1 (restore needs it);
the reference fold at
`inventory-impl-root/inventory-impl-pg/src/test/resources/measurements/structure-analysis.py`;
PLAN.md Phase 23 "recorded, not adopted".

## 5. Catalog the real medium, end to end

Decide the medium root first — the **live tree** (a durable medium), not a
snapshot generation (the filesystem's own history; 13 of them, 1.4 PB
logical). Rename the handful of files with newlines in their names (297
broken manifest lines; the parser refuses the whole manifest at the first),
describe through item 4's streaming route, ask `GET …/data/sections` for the
answer over HTTP, then start `inventory-hasher hash` on the box and let the
content pass run. Revisit size-triage ordering if the wait proves annoying.

Where: [RUNBOOK.md](RUNBOOK.md) "Hashing a data medium";
`measurements/results/README.md` and `mediaX-structure-2026-08-29.txt` (what
the analysis already found: 81,513 duplicated sections, ~19.3 TB within one
generation); PLAN.md Phase 23. *Gate: the 19.3 TB answer comes from the
product over HTTP, and the first MERKLE-confirmed duplicate exists.*

## 6. Backup, export, and disaster recovery (Phase 24)

Confirm the decisions (D4 no DbUnit, D8 the restore surface, D10 the asset
archive, D11/D12 the native kind), then step 0: the restore surface in the
api, proven by the parity kit — the api break every later step depends on and
the one that gets dearer the longer features accumulate on the api.

Where: [IMPORT_EXPORT.md](IMPORT_EXPORT.md); PLAN.md Phase 24.

## 7. The remaining parity kits (Phase 20 step 0's tail)

Assets/regions, auth, audit. No external blockers; the kit has caught three
real bugs so far. Filler for whenever an item above is waiting on a build or a
hash run.

Where: PLAN.md Phase 20, step 0.

## 8. External scanning (Phase 25)

Confirm D1 (one tool, one language) and D6 (CI builds the five binaries),
then steps 1–4: the offline `scan` mode with a local journal, the resumable
upload processed as a job, the web-app downloads/upload pages, the CI build
matrix with checksums and cosign. Step 0 is item 4.

Where: [EXTERNAL_HASHING.md](EXTERNAL_HASHING.md); PLAN.md Phase 25.

## 9. The next release, when there is one

Not now (owner, 2026-08-28). When it comes, the order is forced by the
train's own guard: `artifex-maven-parent 3` → `inventory-parent 3` → repoint
every module from `3-SNAPSHOT` → `train-bom` / `train-apps` restore the
release pins → the 0.2.1 break train carries everything queued since 0.2.0.

Where: [RUNBOOK.md](RUNBOOK.md) "The library release train"; PLAN.md Phase 22
(the train) and Phase 19.

## 10. Label follow-ups (need the printer, and explicit go-ahead to print)

The x-large field expansion ("plenty of room for additional data") and the
`^LL812`-against-846-pitch drift check across a long run.

Where: PLAN.md ongoing item 14.

## 11. AI-assisted cataloging — a design conversation first

CLI-shaped, no per-transaction service. Nothing written yet beyond the idea.

Where: PLAN.md ongoing item 9.

## 12. Tenancy enforcement, on top of the reserved schema

The schema half landed 2026-08-31, while the changesets were still editable
in place: `inventories` with the seeded zero-ULID default, `items
.inventory_id`, `inventory_members` (recorded, not enforced), and the
owner-confirmed `item_identities` PK `(inventory_id, kind, value)` — a
marker claims per inventory, not globally. What remains waits deliberately
behind item 1's gate:

- The authz model — role vocabulary, what `admin` means multi-inventory,
  who creates inventories (Phase 27 step 1, decisions first).
- The api break: every read takes a visibility scope; `scopedTo(…)` beside
  `actingAs`; both backends, the TCK, bus role maps, resources, web-app,
  iOS (step 2).
- Inventory management: create, membership, transfer-between — markers move
  with their item (step 3).
- Virtual inventories: A+B as a read-time union; `findOverlappingMedia`
  across the union is the flagship (step 4).
- Marker resolution scoping: `findByIdentity` gains the scope it
  deliberately lacks; `/i/<ulid>` stays global (step 5).

Where: PLAN.md Phase 27 (the whole design, and the open decisions).

## Waiting on things outside this repo

- **Apple Developer enrollment** (refused: "Action not allowed") — blocks
  Phase 13's paid-account tail, iOS NFC (item 12), and macOS notarization
  (Phase 25 D7; `curl` works meanwhile).
- **Android** — deferred by the owner; no device.
- **Phase 18 visual design** — waits on the owner's reference examples.
- **Hosting at a fixed domain** — deferred by the owner; item 2 makes the
  eventual move a checklist rather than a migration.
