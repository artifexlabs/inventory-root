# DATA_MERKLE.md — Merkle identity for data media

*Staging doc, created 2026-08-27. Follows the UPC_CODE.md / MAVEN_RELEASES.md /
MORE_VERTX.md / DO23_7_5.md lifecycle: plan here, execute, then retire into
PLAN.md as a phase. **Nothing here is built yet.** The point of the doc is to get
the schema right BEFORE it freezes — `005-data.yaml` is still a fresh-install
changeset that can be edited in place, and that window closes the first time a
database anyone cares about runs it.*

## The question this answers

Stated by the owner 2026-08-27, and broader than the original ongoing-item-6 spec:

> "Do I have media that are the same, or alternately where are there duplicated
> sections within my large media inventory?"

That decomposes into three questions with very different costs:

| | question | today |
|---|---|---|
| **A** | Are these two media the same? | `findMirrorsOf`, wrong shape (below) |
| **B** | Where are there duplicated *sections*? | **structurally impossible** |
| **C** | How many bytes are redundant? | works — `GROUP BY hash` |

The original API only ever addressed a narrow slice of A. The owner's standing
intent — *"I always intended data to be identified by merkle hashes but never
explicitly stated it"* — is what this doc writes down.

### Why B is impossible today, precisely

Two facts, neither a bug:

1. **`path_hash` is scoped to the medium.** `PgDataSystem.digest()` hashes the
   *scope-relative* path. So `photos/2019/` on disc A and
   `backup/old/photos/2019/` on disc B produce different `path_hash` values
   despite identical contents. `findMirrorsOf` demands same content AND same
   path, so a relocated section is invisible to it by construction.
2. **Directories are not entities.** `DataEntry` is one row per FILE. A directory
   exists only as a shared prefix of path strings. There is no thing to compare
   when asking whether two *sections* match.

### And why A's current implementation is the wrong shape

`findMirrorsOf` returns `List<DataLocation>` — a per-FILE record — to answer a
per-MEDIUM question. The SQL self-joins `data_entries` against itself and emits
one row for every matching file on every other medium. It computes the complete
file-by-file evidence to answer a yes/no. That is a design mismatch, not a
missing index, which is exactly what the measurement showed.

## Evidence

From `inventory-impl-pg/src/test/resources/measurements/path-layout-measure.py`
run 2026-08-27 against a real 11.5M-path tree (`/mnt/mediaX`, snapshot-heavy,
avg depth 15.6). Full output in that directory's `results/`.

**`findMirrorsOf` does not survive scale, and no index saves it:**

| rows | latency | plan | with `(path_hash, hash)` |
|---|---|---|---|
| 551k | 155 ms | Parallel Seq Scan | 0.9x |
| 2.2M | 848 ms | Parallel Seq Scan | 1.1x |
| 5.5M | **5,528 ms** | Parallel Seq Scan | 1.5x |

Superlinear, ~rows^1.6. At the 50M+ rows a 120 TB medium implies, minutes.

**Small directories dominate, which bounds what any section-matching can report:**

- 25.4% of directories hold exactly one file; **46.7% hold two or fewer**
- 68.6% share their child-name set with at least one other directory
- 7,492 directories whose only file is `pom.xml`; 2,775 only `.DS_Store`
- 10,569 directories shaped `[cover.jpg, metadata.opf, ._cover.jpg, ._metadata.opf]`
  — one per book in a calibre library

**This is the finding that shapes the query surface:** without a size floor, a
name-independent match reports hundreds of thousands of coincidences and buries
the real relocated backup. See "Minimum-size floor" below.

## The three-hash lattice

The central design fact, and the one most easily got wrong: **the three hashes
differ in when they can exist.**

```
                            -- decision 2: a FILE contributes its name AND size
structure(f) = H( "blob" ‖ len(name)‖name ‖ size_be64 )
structure(D) = H( "tree" ‖ sorted[ structure(c) for c in children ] )

content(f)   = the file's content digest                        -- reads every byte
merkle(f)    = H( "blob" ‖ len(name)‖name ‖ content(f) )
merkle(D)    = H( "tree" ‖ sorted[ merkle(c) for c in children ] )

                                       -- the rename-surviving variant drops names
merkle_content(f) = content(f)
merkle_content(D) = H( "tree" ‖ sorted[ merkle_content(c) for c in children ] )
```

| hash | input | available |
|---|---|---|
| `structure` | paths alone | **at ingest**, no file reads |
| `content` (file) | every byte | async, weeks |
| `merkle` (dir) | all descendants hashed | bottom-up, as subtrees complete |

The consequence worth building around: **structure hashing pays on day one.**
"These two subtrees have identical shape and naming" is already a strong
duplicate-backup signal and costs nothing beyond the path decomposition the
ingest already performs. The content Merkle later *upgrades a structural match
to proof*. Ship in that order.

A note on the earlier framing: a "named Merkle" that mixes names AND content
hashes is **just as content-gated** as the pure content Merkle. Only the
names-only `structure` hash is computable early. Naming these three distinctly
avoids the trap.

### Construction rules (get these right or the hashes are worthless)

- **Domain separation.** Prefix leaves `"blob"` and nodes `"tree"`, git-style. A
  directory containing one file must not hash to that file's own digest.
- **Length-prefix every variable-length field.** `H(a‖b)` is ambiguous otherwise:
  `("ab","c")` and `("a","bc")` would collide. Prefix each name with its byte
  length.
- **Deterministic order.** Sort children by their own HASH BYTES, unsigned. The
  name is already inside each child's digest, so sorting by hash is equivalent to
  sorting by name in discriminating power and simpler to implement — a parent only
  ever holds its children's hashes, never their names. What matters is that the
  order never depends on locale collation or Unicode normalization, which would
  make the same tree hash differently on two machines.
- **Empty directories must be representable.** A file-only manifest cannot express
  them, so two trees differing only by an empty directory collide. If directories
  become rows, record empty ones.
- **Algorithm agility.** Directory hashes inherit `HashAlgorithm` from their
  leaves; a tree may not mix algorithms. Store `hash_alg` on directory rows too.
- **Content-only variant** (rename-surviving) is `H("tree" ‖ sorted[child hashes])`,
  omitting names. Powerful, and the reason the size floor is mandatory.

## Schema changes

**All of this folds into the existing `005-data.yaml`. There is NO `006-*.yaml`.**
The changesets were collapsed to five domain files on 2026-08-23 precisely
because nothing had ever been deployed, and that is still true. The rule that
made the collapse worth doing still holds: **no changeset ALTERs a table another
changeset created.** A `006-merkle.yaml` altering `data_entries` would
reintroduce the archaeology the collapse removed — and freeze it there
permanently the moment the schema is applied somewhere real.

*Verification for an in-place edit:* re-run the same `pg_dump --schema-only`
before/after diff the collapse used, so the rewrite is proven rather than
assumed.

### 1. `data_entries` — nullable hash, state, and the archive link

The load-bearing change. Today `hash bytea NOT NULL`, and `DataEntry`'s compact
constructor *also* rejects a blank hash:

```java
if (hash == null || hash.isBlank())
  throw new IllegalArgumentException("a data entry requires a content hash");
```

Both must relax. There is currently **no representation for "known to exist, not
yet hashed"**, which is the entire premise of async hashing.

```
hash          bytea        NULL          -- null = not yet computed
hash_alg      smallint     NULL          -- null with hash
hashed_at     timestamptz  NULL
hash_state    smallint     NOT NULL DEFAULT 0   -- 0 pending, 1 done, 2 unreadable
archive_item_id varchar(26) NULL REFERENCES items(id)  -- decision 4; see below
```

`hash_state=2` (unreadable — permissions, bad sector) matters: without it a
permanently failing file blocks its ancestors' Merkle forever.

**But marking it does not by itself solve the problem, and the doc should not
pretend otherwise.** A directory containing an unreadable file has no honest
content Merkle — its true contents are unknown. Three options, and one must be
chosen before the schema freezes because two of them need a column:

  a. **Null forever.** Honest, and the whole ancestor chain to the root loses its
     Merkle — one bad sector costs the entire medium its identity. Too brittle.
  b. **Hash over readable children, plus `unreadable_files > 0` as the partial flag.** The Merkle is
     computable and comparable, but two partials are only equal if their
     unreadable sets coincide — so the flag must be honoured at query time, never
     silently.
  c. **Treat unreadable as a distinguished leaf value** (e.g. the digest of a
     fixed sentinel plus the file's name/size). Makes the tree total, and two
     media damaged in the SAME place still match — which is arguably correct for
     "are these the same disc?" and arguably wrong for "is my backup intact?".

**DECIDED 2026-08-27: (b), extended.** Hash over readable children and mark the
directory partial — but the unreadable set must be *contractually recorded*, not
merely counted. The owner's reasoning reframes it: an unreadable set is not
comparison metadata, it is an **actionable repair index**. If disc A cannot read
a file and disc B can, that is a restore.

Two consequences follow:

- `data_dirs.unreadable_hash = H(sorted[path_hash of unreadable descendants])`.
  This makes "identically damaged" an O(1) column compare instead of a set
  comparison, so partial equality is sound **by construction** rather than by
  every query remembering to honour a flag — which was the failure mode that
  made (b) look risky in the first place.
- A `data_unreadable` table carries the actionable detail (first seen, last
  attempt, attempt count, reason), keyed back to the entry.

Note what makes the repair query possible: an unreadable file has **no content
hash**, so the only key you have is its PATH. Sibling media are found by
`path_hash` — which gives the path-equality semantic being retired from
`findMirrorsOf` a genuine second purpose.

### 2. Directories become rows

```
data_dirs (
  item_id      varchar(26) NOT NULL REFERENCES items(id) ON DELETE CASCADE,
  path_ids     bigint[]    NOT NULL,      -- finally gives path_elements a reader
  path_hash    bytea       NOT NULL,      -- scope-relative, same as data_entries
  path_text    text        NOT NULL,
  depth        int         NOT NULL,
  structure_hash bytea     NOT NULL,      -- available at ingest
  merkle_hash    bytea     NULL,          -- null until subtree fully hashed
  merkle_content_hash bytea NULL,         -- name-independent variant
  hash_alg     smallint    NULL,
  subtree_files  bigint    NOT NULL,      -- the size floor reads these
  subtree_bytes  bigint    NOT NULL,
  pending_files  bigint    NOT NULL,      -- descendants still unhashed; 0 = merkle computable
  unreadable_files bigint  NOT NULL DEFAULT 0,   -- decision 6: count, for the coarse filter
  unreadable_hash  bytea   NULL,          -- decision 6: H(sorted[path_hash of unreadable
                                          -- descendants]). Makes "identically damaged" an
                                          -- O(1) compare, so partial equality is sound by
                                          -- construction, not by query discipline
  PRIMARY KEY (item_id, path_hash)
)
CREATE INDEX ON data_dirs (structure_hash) WHERE subtree_files >= 8;
CREATE INDEX ON data_dirs (merkle_hash)    WHERE merkle_hash IS NOT NULL;
CREATE INDEX ON data_dirs (merkle_content_hash) WHERE merkle_content_hash IS NOT NULL;
```

`pending_files` marks completion: at zero, the directory's Merkle is computable.
**Written only by the periodic bottom-up sweep, never per-file** — see decision 1
for why the incremental counter was rejected (91x the writes, and a hot root row
that would serialise every hasher).

### 3. `data_unreadable` (new) — the repair index

Decision 6's actionable half. The count and digest on `data_dirs` answer "is this
directory partial, and identically so?"; this answers "what exactly is missing,
and can a sibling medium supply it?"

```
data_unreadable (
  item_id      varchar(26) NOT NULL,
  path_hash    bytea       NOT NULL,
  first_seen   timestamptz NOT NULL,
  last_attempt timestamptz NOT NULL,
  attempts     int         NOT NULL DEFAULT 1,
  reason       text,
  PRIMARY KEY (item_id, path_hash),
  FOREIGN KEY (item_id, path_hash) REFERENCES data_entries (item_id, path_hash) ON DELETE CASCADE
)
```

The repair query joins these to sibling media on `path_hash` where
`hash_state = 1`. Note WHY path is the key: an unreadable file has no content
hash, so path is the only handle that exists — which is exactly the semantic
being retired from `findMirrorsOf`, finding a better use.

### 4. Why `archive_item_id` is now required

`mintArchive` names the archive item `entry.fileName()` — the BASENAME:

```java
.execute(Tuple.of(id, entry.fileName(), containerId, ...))
```

and `retireArchives` finds archives by `container_id = ? AND data_archive = true`.
So two archives named `backup.zip` at different paths on one medium are
indistinguishable by name + containment. That was tolerable while archives were
opaque; decision 4 makes the entry-to-item link load-bearing, so it needs to be
explicit.

### 5. The trigram index the measurement already settled

Independent of Merkle, and proven: `entriesOf`'s `lower(path_text) LIKE '%x%'`
cannot use a btree and reached 745 ms at 5.5M rows; a `pg_trgm` GIN holds it near
40 ms. Cost ~217 bytes/row and a 5.5-minute build at 5.5M.

```
CREATE EXTENSION pg_trgm;
CREATE INDEX idx_data_entries_trgm ON data_entries USING gin (lower(path_text) gin_trgm_ops);
```

## Ingestion (decision 3)

`ItemsResource.replaceManifest` (`PUT /{id}/data/manifest`) already branches on
content type — `application/json` to `DataEntry.fromJson`, `text/plain` to
`DataResource.parseDigestLines`. The change is what those formats mean.

**Manifest = `find`-shaped, no hashing.** Paths, sizes, mtimes; costs no reads,
so it is fast even on 120 TB:

```sh
find /mnt/x -type f      -printf '%s\t%TFT%TT\t%p\n'    # size, mtime, path
find /mnt/x -type d -empty -printf '\t\t%p/\n'          # empty dirs, trailing /
```

A trailing `/` marks a directory, which is how empty directories become
expressible — required for structure hashes to be sound, since two trees
differing only by an empty directory would otherwise collide.

**`sha256sum` moves to a hash-completion route**, feeding results into rows that
already exist rather than creating them:

```sh
sha256sum -- files... | POST /api/v1/items/{id}/data/hashes
```

It always presupposed the hashing this design moves OUT of ingest, so this is
returning it to its actual role. It stays byte-compatible with coreutils
output, including the `*` binary-mode marker `parseDigestLines` already strips.

`DataEntry.of(path, 0L, algorithm, hash)` — the current call, which hardcodes
size to zero — disappears with it. **JSON ingestion is unaffected**;
`fromJson` already reads `sizeBytes`, `mimeType` and `modifiedAt`.

### `replaceManifest` must stop destroying hashes

**The trap that makes or breaks the async design.** `replaceManifest` calls
`retireArchives` and then `storeScope`, which runs `DELETE_SCOPE` followed by
`INSERT_ENTRY`. Re-scanning a disc therefore discards weeks of hashing — for the
medium AND, via `retireArchives`, for every archive on it.

It must instead carry `hash`, `hash_alg`, `hashed_at` and `hash_state` forward
for entries whose `(path_hash, size_bytes, modified_at)` are unchanged, and
reset state only where they differ. This is why decision 3's mtime matters:
without it, "unchanged" cannot be established and every re-scan is a full
re-hash.

## The restartable hashing worker

Hashing a large tree takes **weeks**, across removable media that get unplugged.
Interruption is normal, not exceptional, so progress must be durable per FILE,
not per medium.

The codebase already owns this pattern: the projector's `consumer_cursors`. A
hasher is another consumer.

- **Claim** a batch: `SELECT ... WHERE item_id=$1 AND hash_state=0 ORDER BY ...
  LIMIT n FOR UPDATE SKIP LOCKED` — `SKIP LOCKED` lets several hashers share a
  medium without coordination.
- **Verify before trusting**: re-check `size_bytes` and `modified_at` before
  storing a hash. A file that changed since the manifest was taken must be
  re-manifested, not silently hashed as if unchanged.
- **Idempotent**: re-hashing a done file is a no-op. Crash mid-batch loses at
  most the batch.
- **Medium absent** is not a failure — pause the medium, do not mark files
  unreadable. Distinguish "cannot reach the disc" from "cannot read the file".
- **Progress is observable**: `pending_files` on the root directory *is* the
  medium's progress bar, for free.

## Query surface

`findMirrorsOf` is replaced. The medium-level question wants counts, not rows:

```java
/** Media that overlap this one, most-complete first. */
CompletionStage<List<MediumOverlap>> findOverlappingMedia(String itemId);
record MediumOverlap(String itemId, String itemName,
                     long sharedEntries, long sharedBytes,
                     long theirEntries,  long ourEntries,
                     boolean identical, boolean contains) {}
```

`identical` = root Merkles equal. `contains` = ours is a subset of theirs. That
distinguishes the three cases the current return type conflates: identical,
superset ("which backup is newer"), and mere partial overlap.

Section matching is new:

```java
/** Directory subtrees duplicated elsewhere, honouring a size floor. */
CompletionStage<List<SectionMatch>> findDuplicateSections(SectionQuery q);
record SectionQuery(String itemId,        // null = across the whole inventory
                    Match match,          // STRUCTURE | MERKLE | CONTENT
                    Scope scope,          // ACROSS_MEDIA | WITHIN_MEDIUM | BOTH
                    int minFiles, long minBytes, int minDepth,
                    int page, int size) {}
```

**Within-medium duplication is a first-class case, not an edge case.** The tree
this was measured against is `/mnt/mediaX`, 100% snapshot generations — the
duplicated sections that matter most there are *on the same medium*, between
`.snapshots/5160/` and `.snapshots/5161/`. A design that only compares medium A
to medium B would miss the owner's own motivating data entirely. Note the
interaction: with `WITHIN_MEDIUM`, a directory trivially matches itself, so the
query must exclude self-matches by `path_hash`, not merely by `item_id`.

### Minimum-size floor — mandatory, not optional

The measurement is unambiguous: with 46.7% of directories holding ≤2 files and
68.6% sharing a child-name set, an unfiltered query returns mostly coincidence.
**`minFiles` must have a non-trivial default** (8 is a reasonable starting point;
tune against real results). `minDepth` alone will NOT do the job — those 7,492
lone-`pom.xml` directories sit at many different depths. Size is the filter that
works; depth is a useful secondary.

The partial indexes above bake the floor in, keeping them small.

## API break

`inventory-api` changes, so this rides a break train, not a patch:

- `DataEntry.hash` becomes optional (compact constructor relaxes)
- `DataEntry` gains nothing else — directories are not `DataEntry`s
- `DataSystem.findMirrorsOf` **removed**, replaced by `findOverlappingMedia`.
  Verified blast radius, wider than an interface change: `DataSystem` (api),
  `PgDataSystem` AND `InMemoryDataSystem` (both backends), `DataStorage` +
  `DataVerticle` (bus), `BusActions.DATA_MIRRORS` + its role-map entry, the HTTP
  route `ItemsResource` `/{id}/data/mirrors`, and **`DataSystemTck`**
- `findByHash` is UNAFFECTED and stays as-is — it answers a different question
  (same bytes anywhere) and the measurement shows it indexed and fast (0.19 ms at
  5.5M rows)
- `DataSystem` gains `findDuplicateSections`, and hashing-worker operations
  (claim/complete/fail a batch) — possibly a separate `DataHashing` interface so
  `DataSystem` stays a read/describe surface
- new `BusActions` for each, with role mappings

Pre-1.0 makes this acceptable; the 0.2.0 train's precedent is that one break
train should carry everything queued.

**The parity TCK encodes the semantic this reverses.** `DataSystemTck` currently
asserts, in as many words:

```java
assertTrue(mirrors.stream().noneMatch(m -> m.itemId().equals(elsewhere)),
    "same content at a different path is not a mirror");
```

That is precisely the rule section matching exists to relax — relocated content
IS the thing we want found. So this is a deliberate behavioural change, not a
test that needs updating to compile. Both rules should end up expressed: path
equality still governs `findOverlappingMedia`, while `findDuplicateSections`
deliberately ignores location. Write the TCK so the distinction is explicit, or
a later reader will "fix" one of them back.

## Staged execution

1. **Schema + structure hashing (no content).** Directory rows, structure hashes
   computed during path decomposition, `hash` nullable with state, hashes carried
   across `replaceManifest`, trigram index. `findDuplicateSections(STRUCTURE)`
   works immediately. *Gate: on the real 11.5M `/mnt/mediaX` tree, structural
   sections found WITHIN one medium (the `.snapshots/5160` vs `5161` case) as
   well as across media, with the size floor suppressing the lone-`pom.xml`
   class of match; parity TCK green on both backends.*
2. **The hashing worker.** Claim/verify/complete, `SKIP_LOCKED`, medium-absent
   handling, `pending_files` maintenance. *Gate: a kill-and-restart drill — the
   projector's own gate, reused — proving no file is hashed twice and none is
   skipped.*
3. **Merkle rollup + the medium-level query.** `merkle_hash`,
   `merkle_content_hash`, `findOverlappingMedia`. *Gates: (a) two synthetic media,
   one holding a relocated copy of a subtree of the other, found by MERKLE and
   provably missed by the old path-equality logic; (b) a renamed-but-identical
   directory found by CONTENT and NOT by MERKLE, proving the two variants differ
   as designed; (c) `identical` and `contains` both demonstrated on constructed
   media, since those are the flags that replace the old return type.*
4. **Retire into PLAN.md** as a phase; delete this doc.

## Costs and risks

- **Storage.** Directory rows are ~1 per 6 files in the measured tree (689k dirs
  per 4M files), each carrying up to three 32-byte hashes. Modest beside the
  trigram index's ~217 bytes/row.
- **The content-only variant will surprise people.** Name-independent matching is
  the powerful one and the noisy one. Ship it behind an explicit `Match.CONTENT`
  rather than as a default.
- **`pending_files` is a denormalization** and can drift after a crash mid-update.
  A periodic reconciliation sweep should be able to rebuild it from scratch.
- **Weeks-long jobs need an operator story** — start, pause, progress, abandon —
  in the RUNBOOK before the worker ships, not after.
- **Hardlinks and reflinks** make the same bytes appear at several paths on ONE
  medium; that is real duplication to report, not an error.
- **Symlinks** are not files and must not be hashed as their targets; decide
  whether they appear in a manifest at all.

## Explicitly NOT in scope

Stated so a later reader does not assume these were forgotten:

- **Block-level or content-defined chunking.** This identifies whole files and
  whole subtrees. It will not tell you that two 40 GB video files share 90% of
  their bytes. That is a different (and much more expensive) system.
- **Fuzzy or similar-content matching.** Merkle equality is exact. A directory
  where one file changed does not match, and will not "nearly match".
- **Deduplicating storage.** This is an inventory that REPORTS duplication. It
  never moves, links, or deletes anyone's data.
- **Verifying that a medium is still intact.** Re-hashing to detect bit-rot is a
  natural neighbour of this machinery, and deliberately a separate concern —
  the hash worker records what it read, it does not audit what changed.

## Decisions taken (2026-08-27, with the owner)

1. **Sweep-populated `pending_files`, no incremental counter.** Measured on the
   real tree (avg depth 15.62, ~1 directory per 5.8 files): a counter costs
   **781M ancestor UPDATEs at 50M files — 91x the sweep**. Worse, every file
   completion must update the ROOT row, making it a hot row that every hasher
   contends on and defeating the `SKIP LOCKED` parallelism the worker depends
   on. The column stays; only the periodic bottom-up pass writes it, which also
   makes crash recovery free — the sweep recomputes from ground truth, so there
   is no drift to reconcile. Expressible as a loop over `depth`, max down to 0.

2. **`structure` includes names AND sizes.** Free — `size_bytes` is already on
   the row — and it breaks up the coincidental matches the measurement found
   (7,492 lone-`pom.xml` directories, 10,569 identically-shaped calibre book
   directories) which a names-only hash would collapse together. Cost accepted:
   a re-compressed or re-encoded copy no longer matches structurally.

3. **Ingestion becomes `find`-shaped; `sha256sum` becomes a hash-completion
   feed.** Decisions 2 and 3 turned out to be one question. `parseDigestLines`
   hardcodes `0L` for size, so every `sha256sum`-ingested medium has
   `size_bytes = 0` — which would have silently no-opped the `minBytes` floor,
   left `subtree_bytes` at zero, and made `summaryOf().totalBytes` meaningless.
   `find -printf '%s\t%TFT%TT\t%p\n'` costs no reads and yields exactly what
   the async design needs: sizes, mtimes (which hash-preserving
   `replaceManifest` requires), and a way to express empty directories.
   `sha256sum` output always presupposed the hashing we are moving OUT of
   ingest; it becomes the completion format, which is what it always was.

4. **Archives participate fully, scanner included.** At the schema level this is
   nearly free: `mintArchive` already makes an archive an item with its own
   manifest, so an archive item's root Merkle lands in the same indexed column
   as any directory's and `photos-2019.zip` matching loose `photos/2019/` is a
   plain equality join. One addition IS required — `data_entries.archive_item_id`
   — because `mintArchive` names the item `entry.fileName()`, the BASENAME, so
   two `backup.zip` at different paths on one medium are indistinguishable by
   name+containment today. The scanner and inner-file extraction are the real
   cost and ride in stage 2.

5. **Depth-first per medium.** Finish a mounted disc so it can be shelved;
   matches removable-media reality. Accepted consequence: duplication answers
   arrive only as media complete. See "Recorded, not adopted" below.

6. **Unreadable: hash readable children + recorded unreadable set.** See the
   detail under schema change 1 above.

## Recorded, not adopted

**Size-triage within a medium.** A file whose `size_bytes` is unique across the
inventory cannot be a duplicate of anything, so hashing it answers no question.
Hashing size-collision groups first — the standard fdupes/rdfind triage — would
surface duplicates far sooner at no correctness cost, and decision 3 makes it
possible by making sizes real. It loses to decision 5 only on "can I shelve this
disc yet". Worth revisiting after stage 2 if the wait proves annoying; it is a
secondary ordering WITHIN a medium, so it does not conflict with depth-first.
