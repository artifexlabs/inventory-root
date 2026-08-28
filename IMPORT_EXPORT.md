# IMPORT_EXPORT.md — backup, export, and disaster recovery

*Staging doc, created 2026-08-28. Follows the UPC_CODE / MAVEN_RELEASES /
MORE_VERTX / DO23_7_5 / DATA_MERKLE lifecycle: plan here, execute, retire into
PLAN.md as a phase. Nothing here is built yet.*

## What was asked (the first draft, kept for the record)

1. The reason: backup — and a full disaster-recovery dataset, data AND assets.
2. A signal puts the system into READ ONLY mode; a second signal takes it out.
3. While read-only, "export the data". An export locks out changes, answers a
   "stop this process" signal, and stopping returns the system to normal.
4. The system tracks the last export and dumps the changes since it, so that
   **one export + 0..n updates loaded into an empty system produces a working
   instance.**
5. Exports are DbUnit datasets (latest DbUnit; json/xml/yaml, whatever works)
   with the Liquibase schema version baked in, importable into another instance.

   Restated by the owner on review (supersedes 4 and the format latitude in
   5): the output need not be human-readable, compressibility is wanted, and
   it **must** support (a) a **full backup** that can be restored to exactly
   its point in time, and (b) an **incremental backup** since the last backup
   *or* since the last full backup, **chosen at export time**.

   Added by the owner, 2026-08-28:

6. An export can alternately be **"native"** and use native tooling as the data
   exporter (e.g. `pg_dump`). A native export must be a **full** export and it
   must return to **its own type and changeset** of database. Having a native
   export format is **not a requirement** for a type of database impl.
7. **The changesets for a given export are written to the export**, and are
   available to the export as the means of fixing a database to its intended
   catalog state.

Requirement 1 is the goal; 2–7 are how. This doc keeps 1 intact and reshapes
2–5 where they would break; 6 and 7 are taken as stated.

## The locked principle (owner, 2026-08-28)

**Portability trumps ease of implementation, every time.** The export may be
slow, may take a long time, may be hard to write and to debug. What it may
not do is impede translating an installation from one backend storage type
to another — **including where assets are stored.**

Consequences, so nothing below has to re-derive them:

- Persistence is a choice each deployment makes behind the `inventory-api`
  seam (Phase 20 stages MySQL, SQLite, MongoDB, DynamoDB as opt-in backends).
  The backup is part of the **product**, so it must work for whichever store
  an installation chose, and moving between stores is *the same operation*
  as restoring.
- **The portable backup format is exactly the api's expressive power.**
  Anything a backend stores that cannot be read back *and written back*
  through `inventory-api` is, by definition, not portably backed up. Where
  that is unacceptable the api grows (and the parity kit proves the growth on
  every backend); where it is acceptable the fact is declared derived. Never
  a third option of reaching into a backend.
- **Nothing backend-generated appears in the portable format**: no sequence
  numbers, no dictionary ids, no vendor SQL in the restore path. Identity is
  ULIDs and api-level keys, which every backend already stores as strings.
- **Asset location is not a property of the backup.** Bytes travel through
  `AssetStore`; the implementation on each side decides where they live
  (Postgres `bytea` today, an object store tomorrow). The format never
  records a location.
- **Native tooling is a *kind* of export, never the path of record for
  translation** (requirement 6). A native backup is full, returns only to its
  own backend type at its own changeset, and no backend is required to offer
  one. It exists because it is fast where it exists; it can never be the
  reason a translation is impossible, because the portable kind is always
  there too.
- **Every export carries its own schema** (requirement 7): the changesets
  that bring an empty database to the state the data was shaped for. A
  restore never depends on finding the right changeset jar somewhere else.

## Where the first draft breaks, concretely

Each point below was checked against the code, the schema, and the tools.

### 1. "Signal the system" — there is no single system to signal

Writers to the database today, and how each reaches it:

| writer | path | would a bus-held read-only flag stop it? |
| --- | --- | --- |
| inventory-server | `StorageVerticle`; every write is a `BusActions` WRITE action | yes |
| inventory-web-api (embedded mode) | the same verticles, in-process | yes |
| inventory-projector | **direct Pool**: `projections`, `consumer_cursors` | **no** |
| inventory-hasher | **direct Pool, from another machine**: claim, complete, rollup | **no** |
| `just migrate` | Liquibase CLI | **no** |
| a clustered second server | its own guard | only if the flag is cluster-wide |

A flag held in a verticle stops two of six writers. The hasher is the worst
case: it runs on the box the disc is mounted on, for weeks, talking to
Postgres directly *by design* (a claim is a lease — PLAN.md Phase 23).
**Read-only has to be enforced by the database**; the bus can only mirror it
for a friendlier error.

### 2. Read-only breaks things nobody thinks of as writes

- **Login is a write.** `auth.login` issues a token — `INSERT INTO api_tokens`
  — and an OIDC exchange may `user.create`. Read-only means *nobody new can
  log in*, and a refusal that tries to audit itself needs the audit write to be
  allowed to fail without failing the refusal.
- **The hasher mid-run** gets `IllegalStateException("hashing failed")` and
  exits 1 as if broken. Its claims lapse on their own, so nothing is lost —
  but the operator must be told "paused", not "damaged".
- **The projector** drains every 2 s; under read-only it errors every 2 s
  until someone notices.
- Sessions are fine: the webapp's `SessionStore` is memory + file, not
  Postgres.

### 3. "Changes since the last export" has no source to draw from

The audit trail is not a change log. Checked:

- `data.replace` records **counts** (`entries`, `bytes`, `archives`), not rows;
  a 179M-row manifest is one audit row.
- Hashing — `complete()`, `unreadable()`, `rollUp()` — audits **nothing**
  (`PgDataHashing` has zero audit calls; it is a queue, by design).
- `asset.attach` records the attachment, not the bytes.
- `projections` / `consumer_cursors` are written outside the audit and outside
  Liquibase entirely (`ProjectionLoop.ensureTables`, `CREATE TABLE IF NOT
  EXISTS`).

"Dump the changes since" would need per-table `updated_at` columns, tombstones
for deletes, and change capture on every mutating path — a rewrite of
persistence that would *still* miss the hasher unless it kept its own log.
The portable answer is in "The backup model": the small parts travel in full,
the big parts carry their own "since" through the api, and sub-minute RPO is
each backend's native job (WAL on Postgres), outside the product.

### 4. DbUnit is the right tool for the wrong tables

DbUnit **3.5.1** (Central, 2026-08-20; Java 8+) is better than feared: its
`PostgresqlDataTypeFactory` handles `json`/`jsonb` and — new — `Types.ARRAY`
(an `ArrayType` round-trips `bigint[]` as the literal `{1,2,3}` text through
`createArrayOf`), and `bytea` rides the default binary type as base64. So the
schema's Postgres-isms — `bytea` ×11, `bigint[]` ×2, `jsonb` ×1, `timestamptz`
×14 — are all *representable*. Representable is not sensible:

- **Scale.** `data_entries` on the real medium is **179,316,708 rows**
  (measured 2026-08-28). As flat XML with base64 hashes and array literals
  that is ~50 GB of text, and `CLEAN_INSERT` replays it row by row over JDBC —
  hours to days, against a `pg_restore` measured in minutes. The trigram index
  alone rebuilds in ~3 hours at that size.
- **Assets are `bytea` in Postgres** (the Phase 3 decision). Every photo
  becomes base64 inside an XML document DbUnit materializes per row.

And there is a subtler mismatch: **DbUnit's unit is the table.** Two of Phase
20's staged backends (MongoDB, DynamoDB) have no tables, and even between
relational stores the columns differ (`jsonb` → JSON, `bytea` → blob,
`timestamptz` → `DATETIME(6)`). The portability boundary in this system is
not the schema, it is `inventory-api`: every backend already serializes items,
audit events, users and tokens to JSON through the api's factories
(`ItemFactory.serialize`, `AuditEventFactory`, …), and every backend already
*accepts* media as manifests and assets as bytes through the same seam. An
export expressed in those terms imports into any backend that implements the
api — a DbUnit dataset imports into any backend that has those tables. With
readability no longer a requirement, DbUnit's remaining advantage is gone.

**The two things that made `pg_dump` look necessary for portability already
have a backend-independent form of their own:**

- **A data medium is its own portable format.** Its entire `data_*` state is
  (a) the manifest (paths, sizes, mtimes, archive contents), (b) its hash
  completions, (c) its unreadable list. All three are things ingest *already
  accepts*; `data_dirs` is derived and the rollup recomputes it; `path_ids`
  never leaves the database. Export walks each medium and writes those three
  files; restore replays them through the api on whatever backend is
  underneath. The 179M rows are still 179M rows — but as ~30 GB of text that
  streams, not XML that materializes, and the streaming ingest the catalog
  track needs anyway is the same code.
- **Assets are files.** Export `assets/<id>` plus an index through the
  `AssetStore` seam; restore re-stores through it. More DR-honest than base64
  inside XML on *any* backend, and the seam was built for exactly this
  substitution (Phase 15's "object store behind `AssetStore`" escape hatch).

So `pg_dump` is not *needed* for portability. Requirement 6 keeps it anyway,
as the **native kind**: fast where it exists, full only, same type and
changeset only — and an installation on another store simply has no native
kind unless that backend chose to offer one.

### 5. Import order fails on the first real dataset *(superseded by step 0: ordering and sequences are the restore surface's problem, per backend)*

- `items.container_id` is a **self-reference** (`fk_items_container`,
  `ON DELETE SET NULL`, *not* deferrable — Liquibase's default). DbUnit inserts
  in dataset order; a child appearing before its container fails the FK, and
  ULID order is not containment order (an item can be moved into a container
  created later).
- Three `autoIncrement` columns (`audit_events.seq`, `mime_types.id`,
  `path_elements.id`): DbUnit inserts explicit ids and never advances the
  sequence, so the first write after import collides.
- Cross-table FK order (`items` before `item_tags`, `assets` before
  `asset_regions`, `users` before `api_tokens`…) — `DatabaseSequenceFilter`
  sorts it, but only if asked.

### 6. "Baked-in schema version" is not a version, it is the changesets themselves *(reshaped by requirement 7)*

`DATABASECHANGELOG` records applied changeset ids and md5sums; the changeset
jar records its artifact version (`META-INF/maven/.../pom.properties`). A
*version string* is not enough, because the collapse policy edits changesets
**in place** while unreleased — the same changeset id can carry a different
checksum at 0.2.1 than at 0.2.0 — and because a restore onto a fresh machine
may not have the matching jar at all.

Requirement 7 resolves both: the export **carries the changesets** (the
changelog master and every changeset file, copied out of the changeset jar on
the export's classpath, plus the jar's artifact version and the applied
`DATABASECHANGELOG` state). A restore brings an empty target to exactly that
catalog state *from the bundle*, and verifies a non-empty target against it,
checksum by checksum. No comparison of version strings is needed because the
schema itself is in hand.

The single changeset artifact is already the plan for every Liquibase backend
(Phase 20's taxonomy: one artifact, `dbms`-qualified changesets for each
relational dialect), so one bundle serves a restore onto any relational kind.
A non-Liquibase backend bundles its own bootstrap descriptor in the same slot.

The projector's two tables are outside Liquibase, so the bundle omits them
by construction. They are **derived** (rebuilt by replaying `audit_events`);
a restore leaves them absent and the projector recreates them — so any
external consumer of projections sees a replay.

### 7. The export is a credential dump

`api_tokens.token` stores the bearer token itself. Every backup therefore
contains every live API credential. Correct for DR — tokens must survive —
but the file is a secret: encrypt at rest, restrict who can fetch it, never
commit a sample.

### 8. Where does the export run, and where does it land?

An export needs the api (a `Pool`, in practice), so it runs inside
inventory-server as a job and writes to the server's disk. DR needs the file
*off* the box. The draft has a "stop" signal but no "get it out" path.

### 9. The api cannot restore identity — the finding that orders the plan

Checked against every store interface in `inventory-api`:

| fact | read back? | written back WITH its identity? |
| --- | --- | --- |
| items (id, container, tags, identities, dataInfo, timestamps) | yes — `ItemFactory.serialize` is complete | **no** — `createItem(name, displayName, type)` mints the ULID; `updateItem` on an unknown id returns `false` |
| archive items minted by a manifest | yes | **no** — `replaceManifest` re-mints them |
| assets (metadata + bytes) | yes — `get`, `listFor` | **no** — `store(...)` mints the id; `asset_regions` point at asset ids |
| the asset archive (`asset_archive`, superseded bytes) | **no** — written inside `replace`, no api read path | no |
| asset regions | yes | **no** — `createRegion` mints |
| users, identities | yes | **no** — `ensureUser` mints; `linkIdentity` needs the minted id |
| api tokens (the secret itself) | yes — `TokenInfo.token` | **no** — `issue(user)` mints the value |
| audit events | yes, with their ULID ids | yes — `record(AuditEvent)` takes the id — but not idempotently (a repeat is a PK violation, not a no-op), and ordering leaks a backend `seq` through `AuditReader.since` |
| media: manifest, hashes | yes | yes — `replaceManifest` takes hashed entries |
| media: unreadable (reason, attempts, first seen) | yes | partly — `unreadable(item, path, reason)` restores the fact, resets `attempts` and `first_seen` |
| `hashed_at`, claims, `data_dirs`, dictionaries, projections | — | derived or transient; not carried |

The first row is the one that matters: **every printed label is an item's
ULID on a physical object.** A restore that re-mints ids is not a restore.

Owner's scoping, 2026-08-28, so this is not over-read: a label encodes
`<prefix>/i/<ulid>`, and the **prefix is deployment configuration, not
data**. Moving an installation from `myinventory.example.org` to
`yourinventory.example.org` means the printed labels point at the old host —
a reprint problem, out of scope here. What must be transparent is the other
axis: **same prefix, different database type, every label still resolves.**
That is exactly what preserving the ULID buys, and nothing more is claimed.
So the api needs a **restore surface** — one operation per store that writes
a fact *with* its identity, idempotently — before a portable backup can
exist, and the parity kit must prove that surface on every backend. That is
step 0, and it is why "hard to write and debug" was accepted up front.

A native backup (requirement 6) sidesteps §9 entirely — the database tool
carries every row and every id as-is — which is precisely why it is allowed
to be fast, and precisely why it can only ever return to its own kind.

## The backup model

What (a), (b), 6 and 7 require, stated so every step below can be checked
against it.

- **Every backup has an identity, a lineage, and its schema.** A backup is a
  directory named by a ULID. Its `manifest.json` records `kind` (`full` |
  `incremental` | `differential` | `native`), `base` (the full backup it
  descends from; itself when full or native), `parent` (the backup it is a
  delta *against*: the previous backup for `incremental`, the base for
  `differential`; none for full or native), the **watermark**, the format
  and api version, per-part counts and sha256s, and — for a native backup —
  the backend kind it belongs to. Beside it, `schema/` holds the changesets
  (requirement 7; §6).
- **The watermark is the snapshot instant**, read on the exporting connection
  at the start of the one transaction (or read-only window — D1) the whole
  export runs in. "Since" always means "since the parent's watermark".
- **Restore to a backup = base + every ancestor up to it**, applied in
  lineage order. A `full` or `native` restores alone; an `incremental` walks
  `parent` back to the `base`; a `differential` is base + itself. That is
  requirement (a) — PITR *to that backup* — and requirement (b), with the
  choice of parent made at export time.
- **A native backup is a full backup taken by the backend's own tool** (6).
  It restores only onto an empty target of the **same backend kind**, whose
  schema is first brought to the bundled changeset state (7) and then
  verified against it, checksum by checksum. It is never incremental, and it
  is never the parent of anything portable: a chain is one kind throughout,
  so a lineage never silently acquires a same-backend-only link.
- **Increments overlap and apply idempotently.** Timestamps come from mixed
  clocks: `hashed_at` and `last_attempt` are server-side `now()`, audit `ts`
  and `assets.updated_at` are the writing JVM's `Instant.now()`, and a
  cluster has several JVMs. So an increment selects `since (parent watermark
  − skew allowance, 5 min)`, and every apply is idempotent **by api
  contract**: the restore surface (step 0) writes each fact by its identity
  and treats an existing identical fact as a no-op; manifests replace
  wholesale; a hash completion is the same digest twice. Overlap costs bytes,
  never correctness — and how a backend achieves the no-op is its own
  business.
- **Deletions need no tombstones**, because the small parts travel in full
  with every backup and the big parts are owned by them: the catalog (items,
  tags, identities, regions, asset metadata, users, tokens) is thousands of
  rows, so every portable backup — full or not — carries all of it, and on
  restore anything absent from the catalog is gone: a medium not in the
  catalog drops its `data_*` rows, an asset not in the index drops its bytes.
  Inside a medium, a manifest is replaced wholesale, so a file deleted from a
  disc is simply not in the next manifest.
- **The big parts are the only true deltas.** Per part, "since parent":
  - audit: events with `ts` after the watermark (overlap + idempotent apply),
    written in ULID-id order. **Never by `seq`** — that is a backend's
    autoincrement, it is regenerated on restore, and the projector's cursors
    that depend on it are derived (D6).
  - media: a medium whose manifest was replaced or renamed since the parent
    (`data.replace` / `data.rename` audit events after the watermark) ships
    its **full** manifest again; every other medium ships only hash lines
    with `hashed_at` after the watermark and unreadable rows with
    `last_attempt` after it.
  - assets: bytes for ids with `updated_at` after the watermark — `replace`
    is an in-place UPDATE on the same id, so "new ids" would miss it.
- **A full backup is a consistent point.** On backends with snapshot
  isolation that is one `REPEATABLE READ` transaction and nothing pauses. On
  a backend without it, the exporter turns maintenance mode (step 3) on for
  the duration — which is where read-only stops being a courtesy and becomes
  the thing that makes the snapshot true. A native backup inherits whatever
  consistency its tool provides (`pg_dump` runs in one snapshot).
- **Identity is preserved, always.** Items, archive items, assets, regions,
  users and tokens restore with the ids and values they had. Nothing in the
  portable format is a backend-generated number.
- **Bytes on disk**: line-oriented, sorted, gzip per file. Not for humans;
  for `zstd`/`gzip`. The real 179M-path listing compressed 16:1 as text
  (31 GB → 1.9 GB, measured); JSON lines of small objects do about as well.
  A native backup's payload is whatever its tool emits (`pg_dump -Fc` is
  already compressed).

## Decisions (proposed; confirm before step 0)

- **D0. The locked principle above governs every decision below.** Where a
  later reader finds a shortcut that would be easier on one backend, this is
  the sentence that says no.
- **D1. Read-only is an operator tool, and an export prerequisite only where
  the store cannot give a snapshot.** On Postgres (and any backend with
  snapshot isolation) an export runs in one `REPEATABLE READ` transaction and
  nothing pauses — a backup never stops hashing or blocks logins. On a backend
  without cross-collection snapshots the exporter turns maintenance mode
  (step 3) on for the duration, because a "full backup" that is not a single
  point in time cannot satisfy (a). Read-only mode also stays as the
  operator's tool for restores, migrations, and deliberate freezes.
- **D2. Read-only is enforced by the store and mirrored by the bus.** On the
  reference deployment `ALTER DATABASE inventory SET
  default_transaction_read_only = on` is the source of truth — it reaches the
  hasher on another machine and every cluster member. Existing app sessions
  are terminated so pools reconnect under the new default. The bus refuses
  WRITE actions with 503 and a `system.read-only` status event, so a user
  gets a sentence instead of a stack trace.
- **D3. The portable backup is the artifact of record.** Three parts in
  application formats — the catalog as api-serialized JSON lines, each
  medium's manifest + hash feed + unreadable list, and assets as files with an
  index — with a lineage manifest and the bundled schema, restoring through
  the *application* (the restore surface, D8), never through a database
  tool, so it works for whatever backend an installation chose and *is* the
  way to move between backends. No application-level change log:
  seconds-to-minutes RPO is each backend's native job, and the two bulk
  domains carry their own "since" through the api.
- **D4. Portable format: api-level JSON lines, gzip per file — not DbUnit.**
  *(The one decision that overrules the first draft's letter; confirm.)* The
  catalog is written as one JSON object per line using the serializations
  the api already defines for every backend (`ItemFactory`,
  `AuditEventFactory`, the user and token factories), media in the ingest
  formats, assets as bytes. DbUnit presumes tables (§4); with readability
  dropped, nothing it offered is left. Compression is gzip (JDK built-in, no
  dependency); the archive is a directory, tarred by the operator or step 4.
- **D5. Every backup carries `manifest.json` and `schema/`.** The schema
  identity is **the bundled changesets themselves** (7) plus the backup
  format version and the `inventory-api` version. Restore brings an empty
  target to the bundled state and verifies a non-empty one against it,
  checksum by checksum; across relational kinds the same bundle applies with
  the target's `dbms`; a non-Liquibase backend bundles and checks its own
  bootstrap descriptor. Also recorded: kind, base, parent, watermark,
  per-part counts, sha256 of each file, the producing app version, the
  backend kind (native only), and the **label prefix** the source was serving
  (`inventory.scan.url` or its equivalent) — provenance, not data: a restore
  whose target prefix differs prints "labels printed before this backup will
  need reprinting" and continues. Restore refuses on a format or api version
  it does not know how to read.
- **D6. `projections` / `consumer_cursors` are derived and not exported.**
- **D7. Every writer treats "the store is read-only" as "paused"** — an
  api-level `StoreReadOnlyException` each backend maps from its own signal
  (SQLSTATE `25006` on Postgres): the hasher exits with a distinct code and a
  plain sentence; the projector logs once and backs off; the bus answers
  503, never 500.
- **D8. A restore surface in the api, proven by the parity kit.** One
  idempotent write-with-identity per store: `InventorySystem.restore(Item)`,
  `AssetStore.restore(AssetInfo, byte[])`, `RegionSystem.restore(AssetRegion)`,
  `UserStore.restore(InventoryUser, identities)`,
  `TokenService.restore(TokenInfo)`, `AuditSink.record` made idempotent by
  id, and `DataSystem.restoreManifest(itemId, entries, archiveItemIds)` so
  archive items keep their ids. Each lands in the TCK, so **no backend can be
  admitted to Phase 20 without round-tripping a portable backup** — the
  principle, made a gate.
- **D9. Backend-generated identifiers never appear in the portable format.**
  Not `audit_events.seq`, not `mime_types.id`, not `path_elements.id`, not
  `path_ids`. `AuditReader.since(afterSeq)` stays as the projector's
  in-backend cursor and is documented as non-portable; the backup orders
  audit by ULID id.
- **D10. The asset archive becomes api-reachable, or it is not portably
  backed up.** `asset_archive` holds superseded bytes with no read path.
  Recommendation: add `AssetStore.archived(assetId)` / `restoreArchived(...)`
  so the portable DR set is complete — the principle says grow the api
  rather than declare bytes lost. Confirm, because it is real api surface for
  a rarely-read table. (A native backup carries the table regardless.)
- **D11. The native kind is optional per backend, full only, same kind and
  changeset only** (6). A backend that offers one supplies a
  `NativeBackup` implementation (export + restore + the "is this target
  empty" check); Postgres offers `pg_dump -Fc` / `pg_restore`. Its
  restore always runs the bundled schema first and verifies against it, so
  the "same changeset" rule is enforced by the export's own contents, never
  by an operator remembering. No backend is required to offer one, and a
  portable backup is always available alongside.
- **D12. Chains are one kind throughout.** A native backup has no parent and
  is no one's parent. This keeps "restore to a backup" free of the case
  where the base needs one backend kind and the increments would accept any.

## Stepped execution

Each step is a git-flow feature branch, squash-merged, branch kept. Each gate is
a **drill**, and every portable drill runs on BOTH existing backends — the
in-memory twin is a real second store for this purpose, which makes "does this
survive a different backend" a test that runs today.

### Step 0 — The restore surface: the api learns to write facts with their identity

D8 and D10, in `inventory-api`, both backends, and the parity kit. Slow and
careful by design: this is the api break that makes every later step honest.

- One `restore(...)` per store (D8), idempotent by identity: restoring what is
  already there, identically, is a no-op; restoring a different fact under
  the same identity is a **refusal**, not an overwrite (a backup never
  silently wins over live data; the operator empties the target first).
- `AuditSink.record` becomes idempotent by id. `AuditReader.since(seq)` is
  documented non-portable (D9).
- `DataSystem.restoreManifest` preserves archive item ids and unreadable
  detail (`attempts`, `first_seen`, reason) — the two things
  `replaceManifest` + `unreadable()` lose (§9).
- `AssetStore.archived` / `restoreArchived` (D10) — or the explicit decision
  not to.
- A `StoreReadOnlyException` in the api (D7), thrown by each backend from its
  own signal.
- A `SchemaBundle` in the api: how a backend exposes its schema for
  bundling (the Liquibase changelog files and applied state, for every
  Liquibase backend) and how a restore asks it to *apply* or *verify* a
  bundle against a target (7). The optional `NativeBackup` interface (D11)
  sits beside it.

*Gate: the TCK gains a round-trip kit — read every fact through the api,
write it into an EMPTY store of the OTHER backend through the restore
surface, read it back, compare: ids, timestamps, tags, identities, regions,
tokens, audit order, media manifests and hashes and unreadable detail,
asset bytes and archive. Postgres→memory and memory→Postgres both pass. A
second restore of the same facts is a no-op; a conflicting one is refused.
`SchemaBundle` on Postgres round-trips: bundle from one database, apply to an
empty one, verify equal; verify against a database at a different changeset
state refuses.*

### Step 1 — The portable backup: full, incremental, differential

One directory per backup, named by ULID, laid out so every part streams and
every file gzips (D4):

```text
inventory-backup-01K.../
  manifest.json                 format+api version, kind, base, parent, watermark, counts, sha256s
  schema/                       requirement 7
    changelog-master.yaml, changeset/*.yaml   copied from the changeset jar on the classpath
    artifact.properties         the jar's groupId/artifactId/version
    applied.jsonl               DATABASECHANGELOG as applied on the source (id, author, file, md5sum, order)
  catalog/
    items.jsonl.gz              ItemFactory.serialize, parents before children, ALWAYS full
    regions.jsonl.gz  asset-index.jsonl.gz  users.jsonl.gz  tokens.jsonl.gz  ALWAYS full
    audit.jsonl.gz              AuditEventFactory, ULID order; full, or ts > watermark
  media/<itemId>/
    manifest.jsonl.gz           DataEntry.toJson incl. hashes + archive item ids; full, or replaced since parent
    hashes.jsonl.gz             {path, alg, hash, hashedAt}; full, or hashedAt > watermark
    unreadable.jsonl.gz         {path, reason, attempts, firstSeen, lastAttempt}; full, or lastAttempt > watermark
  assets/<assetId>.bin.gz       full, or updatedAt > watermark
  assets/archive/<archiveId>.bin.gz   (D10)
```

Everything is read through the api and written through the restore surface.
Nothing from `data_dirs` (derived; `rollUp` rebuilds it), the dictionaries,
`seq`, or the projector's tables (D6, D9).

- **Export** (`--full` | `--incremental` | `--differential`, the last two
  naming their parent by ULID or defaulting to the latest backup / latest
  full in the backup directory): the watermark is read first; on a backend
  with snapshot isolation the whole export is one snapshot, otherwise it runs
  under maintenance mode (D1). `schema/` is written by the source's
  `SchemaBundle`. Items are emitted parents-before-children so a one-pass
  backend can restore in file order; the restore surface must still accept
  any order (a two-pass backend is allowed to be slow — the principle).
- **Restore** (`<backup-id>`): resolve the lineage (base, then each ancestor
  in order); **refuse** unless every manifest in the chain carries a format
  and api version this build reads and the same `schema/` (7); **apply the
  bundled schema** to an empty target, or verify a non-empty one against it
  and refuse on mismatch; then per backup in order: catalog through
  `restore(...)`, assets (and archive) through the asset restore surface,
  media through `restoreManifest` then `rollUp`, audit through the idempotent
  sink; after the last: drop whatever the final catalog no longer names;
  compare every count to the last manifest; warn if the target's label prefix
  differs from the manifest's (D5). No sequences to advance — nothing
  backend-generated was carried.
- Lives in `inventory-impl-backup` (impl-root reactor, so the round-trip kit
  proves it on both backends in one pass), with `just backup-full` /
  `backup-incremental` / `backup-differential` / `backup-restore` recipes.

*Gate: populate (catalog + one hashed medium with an archive + assets, one
replaced) → full → more writes, including a delete, a manifest re-describe,
an asset replace, hashing, a token issued → incremental → more writes →
differential. Then, into an EMPTY instance of the OTHER backend, schema
applied from the bundle alone (no changeset jar on the target's path):
restore the full alone and get exactly the first state (a); the incremental →
the second; the differential → the third (b, both parents). Every id
identical; a label printed before the backup resolves after it; the parity
TCK's read assertions pass; `findDuplicateSections` and `findOverlappingMedia`
answer identically; counts match. Then export from the restored instance and
diff the two backups: identical modulo watermark. A target already at a
different changeset state is refused.*

### Step 2 — The native kind, on Postgres (requirement 6; D11, D12)

The same directory shape with a different payload:

```text
inventory-backup-01K.../
  manifest.json                 kind: native, backendKind: postgres, watermark, checksums
  schema/                       the same bundle as step 1
  native/inventory.dump         pg_dump -Fc --data-only, taken in one snapshot
```

- **Export** (`--native`): always full; refuses `--incremental` /
  `--differential`; writes `schema/` first, then `pg_dump --data-only` so the
  data file never carries a second, competing copy of the schema.
- **Restore**: refuses unless the target is an **empty Postgres** database
  (D11 — "returns to its own type"); applies `schema/` through Liquibase
  (D11 — "and its own changeset"), then `pg_restore --data-only`, then
  verifies `DATABASECHANGELOG` against `schema/applied.jsonl` and every count
  against the manifest. A non-empty target, or any other backend kind, is a
  refusal with a sentence that names the portable kind as the alternative.
- Implements `NativeBackup` for `inventory-impl-pg`; the in-memory backend
  deliberately implements none, which is the living proof that a backend
  without a native kind is a complete backend.
- The existing `just backup` / `just restore` become this kind's recipes.

*Gate: native export → restore into an EMPTY Postgres with no changeset jar
on its classpath → schema present, `DATABASECHANGELOG` checksums equal the
bundle, every count equal, every id equal, the parity read assertions pass.
Restore into a non-empty database is refused; restore of a native backup
onto the in-memory backend is refused with the portable kind named; an
attempt at `--native --incremental` is refused at export time.*

### Step 3 — Maintenance mode (read-only), enforced where it counts

- `just readonly on|off`: the reference deployment flips Postgres's
  `default_transaction_read_only` on the database and terminates the app
  role's sessions so pools reconnect. Each other backend supplies its own
  switch as a Phase 20 obligation; the api sees only `StoreReadOnlyException`
  (D7).
- **Bus mirror.** `StorageVerticle` refuses WRITE actions with 503
  `system.read-only` while the store reports read-only (a cheap probe,
  cached briefly); `BusGuard` stays out of it — admission is about *who*,
  this is about *when*. A `StatusEvent` `system.read-only` publishes on each
  flip so the webapp can banner it. The refusal itself is not audited.
- **Writers learn "paused" (D7).** `inventory-hasher hash` exits **5** with
  "inventory is read-only; nothing was marked, run again later"; `progress`
  still works. The projector logs once and lengthens its poll. `just migrate`
  refuses while read-only. Login is documented as blocked; existing tokens
  keep working because validation is a read.
- The exporter uses this automatically on backends without snapshot
  isolation (D1).

*Gate: read-only on — every WRITE route 503, every GET 200, login 503, a
running hasher exits 5 within one batch and marks nothing, the projector
idles; off — all resume; the kill-and-restart drill passes across an on/off
cycle; a full backup taken under maintenance mode on the in-memory backend
(which has no snapshots) is consistent.*

### Step 4 — Export as a job: start, watch, stop, fetch

The "signal, stop, and get it out" half of the ask.

- Bus action `admin.backup` (ADMIN; `kind` full / incremental / differential
  / native, optional `parent`) runs step 1's or step 2's export as a **job**
  in a worker verticle: correlated `StatusEvent`s for started / progress /
  finished / cancelled; audited as `system.backup` with kind, counts and the
  watermark. `native` is refused with a sentence on a backend that offers
  none.
- `admin.backup-cancel` stops it; a cancelled job deletes its partial
  directory and publishes `cancelled`.
- Artifacts land in `inventory.backup.dir` (a compose volume) and are listed
  / fetched via `GET /api/v1/admin/backups` and `/{id}` (ADMIN; the file is a
  credential dump — §7). Off-box copying is the operator's `scp` /
  object-store step, documented in RUNBOOK.

*Gate: start → cancel mid-way → directory gone, event says cancelled → start
again → completes → download → step 1's restore drill passes on the
downloaded copy, into the other backend; a native job's download passes step
2's drill.*

### Step 5 — Retire into PLAN.md

As a phase, with the drills' results as the record; delete this doc.

## Explicitly NOT in scope

- **An application-level change log.** Increments come from the watermark
  and columns the api already exposes ("The backup model"); sub-minute RPO
  is each backend's native job (§3), outside the product. WAL archiving and
  PITR are not built.
- **Human-readable output.** Dropped by the owner; gzip'd JSON lines are
  inspectable with `zcat`, which is enough.
- **Data-media rows or asset bytes as DbUnit** — they travel in their own
  formats (`media/` and `assets/` in step 1's layout), which are smaller,
  streamable, and portable (§4).
- **Native increments, or native restores anywhere but home.** Requirement 6
  says full, own type, own changeset; D12 keeps chains one kind. An
  installation that wants either uses the portable kind, which is always
  there.
- **Cross-version restore.** A restore applies the *bundled* schema, so the
  target ends at exactly the source's changeset state; upgrading is each
  backend's migration story run *after* the restore, never a smarter
  restorer.
- **Secret redaction.** DR-completeness requires the tokens (§7); protecting
  the file is operations, not format.
- **Relocating printed labels to a new host.** The label prefix is deployment
  configuration; an installation that changes it reprints (§9). The backup
  records the prefix so the restore can say so, and does nothing else about
  it.

## Costs and risks, stated

- Step 0 is an api break and touches every store on both backends before a
  single byte is exported. That is the price the principle names, and it is
  paid once; every later backend pays it as its admission ticket.
- Restore through the api is slower than any native tool — by hours at the
  179M-row medium (`restoreManifest` is the same streaming ingest the catalog
  track needs; they share the work). Accepted explicitly by the owner; the
  native kind exists for installations that can use it.
- Two kinds means two restore paths to keep honest. The bundled schema is the
  shared spine — both apply and verify the same `schema/` — so a drift
  between them shows up as a checksum mismatch, not a silent difference.
- The bundled changesets are a copy: if a backup is taken from a build whose
  changeset jar was edited in place (the pre-freeze collapse policy), the
  bundle is what that build had, and restore trusts it. That is correct — the
  data was shaped by exactly those changesets — and it is why version strings
  were not enough.
- Terminating sessions on `readonly on` (D2) rolls back in-flight transactions:
  correct, but a user mid-save sees one failure.
- The api serializations become a **file format** the moment a backup is
  written: a change to `ItemFactory.serialize` is a change to what old
  backups mean. The manifest records the app version, and restore must read
  every version ever written — the same discipline `HashAlgorithm.id()`
  already carries ("never renumber a released value").
- A long increment chain restores slowly and is fragile to one lost member;
  the differential option exists for exactly that, and RUNBOOK should say
  "a full every N".
