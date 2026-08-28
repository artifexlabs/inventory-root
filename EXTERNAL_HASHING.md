# EXTERNAL_HASHING.md — scanning a filesystem where the server cannot reach

*Staging doc, created 2026-08-28. Follows the UPC_CODE / MAVEN_RELEASES /
MORE_VERTX / DO23_7_5 / DATA_MERKLE / IMPORT_EXPORT lifecycle: plan here,
execute, retire into PLAN.md as a phase. Nothing here is built yet.*

## What was asked (the first draft, kept for the record)

1. Today `inventory-hasher` reads a *described* medium (the manifest is
   `PUT` first; the hasher then runs where the medium is mounted, talking to
   Postgres directly).
2. An **externally produced, statically linked, single executable** that scans
   some other remote system *locally* and lets a local filesystem be treated
   as a remote data location — one binary each for **Windows x86, macOS x86
   and ARM, Linux x86 and ARM**.
3. The web-app has **download links** for all of them.
4. Workflow: copy the executable to the remote machine (download link or
   `curl`), run it with a **starting location**, an **overridable default
   name**, and flags: **single-filesystem-only** mode, **includes**,
   **excludes**, **quiet**, **verbose up to 3 levels**, and whatever else.
5. It reads the starting location as a medium in the system's sense, like the
   hashing scanner does, writes a **metadata file with as much data as it
   can**, and packs everything into an **archive named by the given name**.
6. An **API endpoint and a web action** upload the archive; the system
   processes it as it would attached data and establishes it as data items
   in the inventory.

Requirement 5's "like the hashing scanner does" is read as: describe AND
hash — paths, sizes, mtimes, and content digests, archive members included —
because that is what makes an upload immediately answerable by every Phase 23
question. The name "location" is not carried forward (§8).

## Where the first draft breaks, concretely

Each point below was checked against the code, the build, or the platform.

### 1. It is a different tool from the hasher, not a copy of it

`inventory-hasher` is **online**: it claims files from the database under a
lease (`FOR UPDATE SKIP LOCKED`), completes them one batch at a time, and
sweeps the rollup — it exists *because* the disc is near a database it can
reach. A remote machine on someone else's network cannot and must not reach
Postgres. So the remote tool is **offline**: it has no queue to claim from,
nothing to verify against, and no server to report progress to. Every
guarantee the hasher gets from the store — restartability, exactly-once,
progress — the remote tool must provide **from the local filesystem**, and
the draft says nothing about any of them.

### 2. A weeks-long scan with one output file at the end loses everything on a crash

The real medium is 179,316,708 paths (measured 2026-08-28); describing it
took days and hashing it is weeks. "Make it into an archive" as the final
step means a power cut on day nine produces nothing. The standing
requirement from Phase 23 — *"it should also be re-startable if
interrupted"* — applies here with no database to lean on: the tool needs an
**append-only journal** it can resume from, and the archive must be
assemblable from a journal at any point.

### 3. The upload cannot be a request body, and ingest cannot be a `String`

Sizes at the real scale: the manifest is ~30 GB of text (1.9 GB gzipped —
the actual `paths-002.tgz`), plus hashes (179M × 64 hex ≈ 11 GB, maybe 6 GB
compressed), plus metadata. Against that:

- `quarkus.http.limits.max-body-size` is **10 MB** by default, and neither
  gateway sets it.
- `ItemsResource.replaceManifest(…, String body)` reads the **whole body
  into a `String`** and then `new JsonArray(body)` — the entire manifest
  materialized twice. The largest manifest that path has ever carried is
  80k entries.
- `DataSystem.replaceManifest(itemId, List<DataEntry>)` takes a **list**,
  and `DataTree.build` / `DataTree.roll` hold a medium's entries in memory
  (Phase 23 recorded this as "not adopted: the streaming fold", and said the
  fix should come with streaming ingest, not before).

So the upload must be **streamed to disk and resumable** (a multi-GB transfer
over a home uplink will be interrupted), and processing must be a **job**
with a **streaming ingest** underneath. That streaming ingest is the same
work IMPORT_EXPORT step 1 (restore) and the catalog track (describing the
real medium) both need; this doc is the third caller, and the one with the
hardest numbers.

### 4. Nothing says which item the upload belongs to

"Establish it as data items" — which item? A fresh one every time means a
weekly re-scan creates a new medium weekly, and Phase 23's hash-preserving
re-describe (which keeps weeks of hashing when a disc is re-scanned) never
triggers because it is always a different item. The scan needs a **stable
identity for the scanned location** that survives re-runs and machine
reboots: hostname + filesystem identity (POSIX `st_dev`/UUID, NTFS volume
serial) + root path, hashed into a fingerprint. The system already has the
place to put it — `item_identities(kind, value) → item`, built in Phase 15
for exactly "a marker resolving to an item" (`upc`, `nfc-uid`, …). A
`scan-location` kind makes re-upload find its medium and re-describe it;
"attach to item X instead" stays available as an explicit override.

### 5. "Statically linked" is only literally possible on one of the five platforms

- **Linux** x86/ARM: yes — GraalVM `native-image --static --libc=musl`
  produces a genuinely static binary.
- **macOS** x86/ARM: Apple does not support static linking against
  `libSystem`; the best possible is a single self-contained executable that
  links only the OS's own libraries. That is what everyone means and it is
  fine, but it is not "statically linked".
- **Windows** x86: same shape — a single `.exe` against the system CRT.

And native-image does **not cross-compile**: each of the five binaries is
built on its own OS/arch. The workspace's native path today is `just native`
through *one* Linux x86 builder container. Five platforms means a **CI build
matrix** (GitHub Actions has `ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-13`
x86, `macos-14` ARM, `windows-2022`) — and that collides with the standing
rule that **releases run from the owner's local machine only; CI verifies,
never releases**. One machine cannot produce five platforms' binaries. This
needs a decision, not a workaround (D6).

### 6. Downloaded binaries hit platform gatekeeping, and one gate is already closed

- **macOS Gatekeeper** quarantines anything a *browser* downloads and refuses
  an unsigned, un-notarized executable outright. Notarization requires a
  Developer ID certificate, which requires the **Apple Developer Program
  enrollment that is currently refused** ("Action not allowed"). Until that
  resolves, the macOS binaries work only via `curl` (no quarantine attribute
  is set) or a manual `xattr -d com.apple.quarantine` — the draft's "download
  link" path is closed on macOS for now.
- **Windows SmartScreen** warns on an unsigned `.exe` and can be clicked
  through; an Authenticode certificate removes the warning.
- **Linux** has no gate; a published sha256 (and a signature) is the whole
  story.

Checksums for every asset are non-negotiable regardless: a tool that hashes
your filesystem and produces an archive you upload to your inventory is
exactly the kind of binary that must be verifiable.

### 7. Two implementations of the same hashing is the drift the parity kit exists to prevent

A second language (Go or Rust cross-compiles static binaries trivially) is
tempting for §5. But the tool's output is a **contract** the server ingests —
path normalization, archive-member listing, mtime precision, the symlink
policy, the exact meaning of "unreadable" — and two implementations of a
contract drift. Phase 23 paid three times for divergences the parity kit
caught *between two Java backends of the same code*; a second language has
no kit. What is genuinely language-neutral is SHA-256 of bytes. Everything
else in the output should come from the same classes the server uses to read
it (D1).

### 8. "Location" already means something else

In this system a **location** is an item of type `location` — a *place*
(Phase 15: locations are containers with coordinates). A scanned filesystem
is a **data medium**: `DataInfo(kind = REMOTE_STORAGE, …)`, exactly the
`MediaKind` Phase 3 reserved for "remote/cloud" data. Calling the scan root
a location would put a hard drive in the same vocabulary as a garage shelf.

### 9. Small things that become large at 179M paths

- **Unicode normalization.** macOS returns file names NFD-ish, Linux returns
  whatever bytes were written. `MerkleHash` length-prefixes *raw* name bytes
  on purpose, so the same folder scanned on two platforms can carry different
  structure hashes. The tool must emit names as the filesystem gives them,
  and the server must not normalize; a copy whose names were re-normalized
  is a different name-set (CONTENT matching still finds it). Stated, not
  hidden.
- **Windows paths**: `\` separators (`DataEntry.normalizePath` already flips
  them), drive letters never appear (paths are relative to the root), NTFS
  100 ns mtimes (truncated to micros like everything else), reparse points
  and junctions (the symlink policy: recorded unreadable by name, never
  followed — Phase 23's rule), long paths (`\\?\` prefix on open).
- **Single-filesystem mode** is `find -xdev`: compare each directory's
  `FileStore` to the root's; Windows volume serials and POSIX device ids both
  come through `Files.getFileStore`.
- **Includes/excludes** change what the manifest *is*: a re-scan with a
  narrower exclude set re-describes the medium with fewer files, and the
  hash-preserving replace drops the rest. That is correct and it is a
  surprise; the metadata records the patterns so the upload can say so.
- **Archive members** (zip family): the tool already reads every byte of a
  zip to hash it; listing its members costs a central-directory read (cheap)
  and hashing them costs a decompression pass (not cheap, CPU-bound). Phase
  23's decision 4 — archives participate fully — holds; `--no-archives`
  exists for the operator who cannot afford it.

## Decisions (proposed; confirm before step 0)

- **D1. One tool, two modes, one language.** `inventory-hasher` gains a
  `scan` subcommand (offline: walk, hash, journal, pack) beside `hash`
  (online: claim/complete against the store). Same repo, same Quarkus
  picocli app, same `DataEntry`/`ZipArchiveScanner`/`MerkleHash` classes the
  server reads with — so the output contract has one implementation and the
  parity kit still covers it. The cost is §5; it is paid in build
  infrastructure rather than in a second implementation.
- **D2. The scan archive is a versioned contract with a conformance kit.**
  `scan-format` v1, defined in `inventory-api` terms (a stream of
  `DataEntry` JSON lines plus a metadata document), with fixture archives in
  `inventory-impl`'s test tree that BOTH the tool's writer and the server's
  reader are tested against. Portability across backends is inherited: the
  reader hands `DataEntry`s to the api, nothing else.
- **D3. Identity of a scanned location is an item identity.** Fingerprint =
  sha256 of (`hostname`, filesystem id, root path), stored as
  `item_identities(kind = "scan-location")`. Upload resolves it to an
  existing medium and re-describes (hash-preserving), or creates one with
  `DataInfo(REMOTE_STORAGE, mutable, locator = "<host>:<root>")` and the
  archive's default name. `--item <id>` at upload overrides.
- **D4. Streaming ingest is a prerequisite, shared three ways.** A streaming
  `DataSystem.replaceManifest` (a `Publisher<DataEntry>` / chunked protocol
  that keeps the transaction and the hash-preserving carry) and a streaming
  `DataTree` fold. This doc, IMPORT_EXPORT step 1, and the catalog track all
  need it; it is built once, first, and gated at the real scale.
- **D5. "Static" means: musl-static on Linux, self-contained on macOS and
  Windows.** Stated on the downloads page in those words.
- **D6. The five binaries are built by CI and attached to a GitHub Release;
  the owner's local machine still cuts the release.** The tag is created
  locally (the standing rule holds for the *decision* to release); the
  workflow that runs on that tag builds the matrix and uploads assets. Java
  jars to Central stay local-only as before. **Owner decision required**:
  this is the first artifact the owner's machine cannot produce.
- **D7. Every asset ships with a sha256 and a signature; macOS notarization
  waits on Apple.** Sigstore/cosign keyless signing in the release workflow
  (free, no certificate); Authenticode and Apple Developer ID when the
  respective enrollments exist. Until Apple resolves, the downloads page
  says "macOS: use `curl`, or remove the quarantine attribute" in plain
  words.
- **D8. Restartability is a local journal.** The tool appends one line per
  finished file to `<name>.journal` and checkpoints the walk; `--resume`
  continues from it; `pack` assembles the archive from the journal at any
  time. Killing the tool at any moment loses at most the file in progress.
- **D9. The upload is a resumable transfer to disk, processed as a job.**
  Chunked with `Content-Range` (or tus), written to `inventory.upload.dir`,
  verified against the archive's own checksums, then processed by the job
  machinery IMPORT_EXPORT step 4 defines (status events, cancel, audit).
  Never a request body.
- **D10. It is a medium, not a location** (§8). Vocabulary in flags, docs,
  and the web-app: "scan root", "medium".

## The scan archive (scan-format v1)

```text
<name>.inventory-scan/            (a directory; `pack` tars it: <name>.inventory-scan.tar)
  metadata.json                   see below
  manifest.jsonl.gz               one DataEntry per line, in walk order, hashes included,
                                  archive members nested as archiveContents
  unreadable.jsonl.gz             {path, reason}  — permission denied, I/O error, symlink, reparse point
  checksums.txt                   sha256 of every file above
```

`metadata.json` (versioned; every field named so "as much as it could"
has an answer):

- `formatVersion`, `tool` (name, version, commit), `scanId` (ULID, minted at
  start, stable across `--resume`), `fingerprint` (D3) and its inputs
  (`hostname`, `filesystemId`, `root`), `defaultName`.
- `os`, `arch`, `filesystemType`, `singleFilesystem`, `includes`,
  `excludes`, `followSymlinks: false` (always), `archives: true|false`.
- `startedAt`, `finishedAt`, `resumed: n`, `files`, `directories`, `bytes`,
  `hashed`, `unreadable`, `archivesListed`, `hashAlgorithm: sha256`.
- `mtimePrecision: micros`, `nameNormalization: none` (§9).

Paths are relative to the root, `/`-separated, as the filesystem gave them.
Timestamps are ISO-8601 UTC truncated to micros. The manifest is exactly what
`PUT /data/manifest` accepts as JSON today, streamed.

## Stepped execution

Each step is a git-flow feature branch, squash-merged, branch kept; each gate
is a drill.

### Step 0 — Streaming ingest (D4), shared with IMPORT_EXPORT and the catalog track

- `DataSystem.replaceManifest(itemId, Publisher<DataEntry>)` (the `List`
  overload becomes a convenience over it), keeping ONE transaction, the
  hash-preserving carry, archive-item reuse, and the derived tree — with
  `DataTree` folding as a stream: entries arrive sorted by path, a stack of
  open directories closes as the prefix changes, memory becomes
  O(widest directory) instead of O(tree). `DataTree.roll` gets the same
  treatment for `rollUp`.
- The text and JSON ingest routes stream the body to disk first and feed the
  publisher from the file; `max-body-size` is raised only for those routes,
  or they move to the resumable upload of step 2.
- The parity kit's `DataSystemTck` gains a streaming manifest test; both
  backends pass.

*Gate: a synthetic 179M-entry manifest (generated, not stored) ingests on
Postgres inside a bounded heap (assert with `-Xmx2g`), `findDuplicateSections`
answers, a second ingest of the same stream keeps every hash; the in-memory
backend passes the same TCK test at a scale it can hold.*

### Step 1 — `inventory-hasher scan`: the offline mode

- `scan <root> [--name <default>] [--one-filesystem] [--include <glob>]…
  [--exclude <glob>]… [--no-archives] [-q | -v | -vv | -vvv] [--resume]
  [--out <dir>]` and `pack <journal-dir>` (also run automatically at the end
  of a completed scan). Globs are gitignore-style, anchored to the root.
- Walk with `Files.walkFileTree`, `NOFOLLOW_LINKS`, `FileStore` comparison
  for `--one-filesystem`, the Phase 23 symlink/reparse policy, long-path
  handling on Windows. Hash with the same `MessageDigest` code `DataHasher`
  uses. List and hash zip-family members through `ZipArchiveScanner` +
  `ArchiveSource`.
- Journal (D8): one line per finished entry, fsync'd per batch; a checkpoint
  of the walk position; `--resume` re-walks and skips journaled paths whose
  size+mtime match (the same "same file" rule the store uses), re-hashes
  the rest.
- Verbosity: `-q` errors only; default one summary line per 10k files;
  `-v` per directory; `-vv` per file; `-vvv` per file with timing and
  archive members. Exit codes: 0 complete, 2 usage, 3 root absent, 4
  completed with unreadable entries (the archive is still valid), 5
  interrupted (journal is valid; `--resume` continues).
- Writes `scan-format` v1 (D2) through the same `DataEntry.toJson` the server
  parses; the conformance kit runs the tool's writer against the server's
  reader.

*Gate: (a) on a synthetic tree with archives, symlinks, an unreadable file,
and a second filesystem mounted inside it, `scan` produces an archive the
server's reader accepts and whose structure hashes equal `DataTree.build`
over the same tree; (b) the kill-and-resume drill: kill at random points
across ten runs, `--resume` each time, the final archive is byte-identical
(modulo `resumed`, `finishedAt`) to an uninterrupted run; (c) Windows path
fixtures (backslashes, reparse point, 100 ns mtime) round-trip through
`normalizePath` and micros truncation; (d) `--one-filesystem` excludes the
inner mount and says so in metadata.*

### Step 2 — Upload and processing: the archive becomes a medium

- `POST /api/v1/data/scans` (WRITE): resumable, chunked (`Content-Range`
  with a returned upload id, or tus), streamed to `inventory.upload.dir`;
  `GET …/scans/{uploadId}` reports bytes received and, after completion,
  processing state.
- Processing is a job (D9; the machinery of IMPORT_EXPORT step 4): verify
  `checksums.txt`; read `metadata.json`; resolve the medium by
  `scan-location` identity (D3) or `--item`; create it if absent with
  `DataInfo(REMOTE_STORAGE, mutable = true, locator)` and the default name;
  refuse a `scanId` already processed (idempotent upload); stream
  `manifest.jsonl.gz` through step 0's `replaceManifest`; record
  `unreadable.jsonl.gz` through `DataHashing.unreadable`; `rollUp`; audit
  `data.scan` with counts and the fingerprint; status events throughout.
- Bus vocabulary: `data.scan-begin`, `data.scan-status`, `data.scan-process`
  (the job), role-mapped and forwarded like the rest of the data actions.

*Gate: upload a step-1 archive of a synthetic tree → medium exists with the
right identity → `findDuplicateSections(STRUCTURE)` and `(MERKLE)` both
answer against a second medium holding a copy → re-upload of a re-scan
resolves the SAME item and keeps every hash → the same `scanId` twice is a
no-op → an interrupted upload resumes and the checksum still verifies → a
tampered `manifest.jsonl.gz` is refused by checksum before any ingest.*

### Step 3 — The web-app: downloads and upload

- A **Downloads** page: one link per platform to the GitHub Release asset for
  the running version, its sha256 beside it, the D5 wording, and the macOS
  `curl`/quarantine note while D7 is blocked. Links point at the release,
  not at bytes the web-app hosts.
- A **Scan upload** action on the media pages: choose file, optional
  "attach to this item", progress from the resumable upload, then the job's
  status stream until "medium ready" with a link to it.
- RUNBOOK gains "Scanning a remote filesystem": the five commands, what
  `--resume` means, what to do with exit 4.

*Gate: page tests pin the links and checksums against the release manifest;
an upload from the page reaches step 2's job; `SpaceAnnotatorPagesTest`-style
test covers the status stream.*

### Step 4 — Five binaries, built by CI, verified before they are trusted

- GraalVM native-image for `inventory-hasher` on five runners
  (`ubuntu-24.04`, `ubuntu-24.04-arm`, `macos-13`, `macos-14`,
  `windows-2022`); Linux with `--static --libc=musl` (D5). The
  `quarkus-reactive-pg-client` dependency rides along for the `hash` mode;
  it is dead weight in `scan` and that is accepted.
- The release workflow (D6): triggered by the tag the owner pushes; builds
  the matrix; runs step 1's conformance kit **against each built binary**
  (the archive it produces must pass the server's reader on that platform);
  computes sha256s; signs with cosign; attaches assets and `checksums.txt`
  to the GitHub Release. Nothing is attached that did not pass its own
  conformance run.
- `just release` learns the tag → CI → assets handoff, and refuses to call
  a release done until the assets exist.

*Gate: a tagged pre-release produces five assets; each downloaded binary
scans the step-1 synthetic tree on its own platform and the archive passes
the conformance kit; the sha256s match `checksums.txt`; cosign verifies; the
downloads page (step 3) resolves every link.*

### Step 5 — Retire into PLAN.md

As a phase, with the drills' results as the record; delete this doc.

## Explicitly NOT in scope

- **A second implementation in another language** (§7, D1).
- **Following symlinks or junctions.** Phase 23's rule stands: recorded by
  name, never followed.
- **Tar-family archives inside the scanned tree.** Zip family only, as the
  scanner today; tar needs commons-compress and is Phase 23's separate
  decision.
- **Serving the binaries from the web-app.** Links go to GitHub Releases.
- **Notarizing macOS binaries** until the Apple Developer enrollment
  resolves; the `curl` path is documented meanwhile (D7).
- **Any online behaviour in `scan`.** It never contacts the server; the
  upload is a separate, later act by a person with a WRITE token.

## Costs and risks, stated

- Step 0 is the largest piece and it is an api change (`Publisher` overload)
  that touches both backends and the tree folds; it is also the piece the
  catalog track has been waiting on. Build it first and gate it at the real
  scale, or everything downstream is proven on toy data.
- The CI build matrix is new infrastructure (five runners, GraalVM on each,
  a Windows build that has never run for this workspace) and D6 changes a
  standing rule. Expect the first green matrix to take several iterations.
- Native-image binaries of a Quarkus app are 40–80 MB each; five of them per
  release is a few hundred MB of assets per tag. Acceptable; noted.
- A scan archive is not a credential dump (unlike a backup), but it is a
  complete description of someone's filesystem; the upload route is WRITE
  role and the upload directory is not world-readable.
- `--exclude` narrows the medium on re-describe (§9); the upload's status
  says how many entries the previous description had that this one does not.
