# DEMO — what this application can show, live

*A demo-day script, written 2026-09-01. Each item says what to show, the
command or URL that shows it, and the trap to avoid. Commands assume the
compose stack ([RUNBOOK.md](RUNBOOK.md) is the executor of record): web-app
at `:8082`, API gateway at `:8081`, projector at `:8083`. Credentials come
from `.env` (`admin@example.com` / `change-me` by default).*

## Before the audience arrives

```sh
just build-all          # fast-jars + natives + images (skip if images are current)
INVENTORY_PRINTER=log just up
just ps                 # migrate shows Exited (0); everything else Up
just smoke              # login → CRUD → real QR PNG → print dispatch → BFF view
```

**Print discipline:** `just smoke` dispatches a REAL label if `.env` points
`INVENTORY_PRINTER` at hardware. Bring the stack up with
`INVENTORY_PRINTER=log` and switch to the real printer only for demo item 3.
The Brother sleeps after ~10 minutes — wake it right before that segment,
and check the loaded stock matches `INVENTORY_PRINTER_FORMAT`.

## 1. The catalog: things, in exactly one place

Log in at `http://localhost:8082/login` (password, or Google OIDC if
configured). Show:

- **Create and edit items** — name, type, description, quantity, weight,
  dimensions, expiration (hard stop vs recommendation), the "heavy" flag
  (human judgment, deliberately not derived from weight).
- **Containment is a tree** — put an item in a crate, the crate on a shelf.
  Moving is re-parenting: a physical thing is in exactly one place, and the
  UI can't express otherwise. Try to put a container inside its own
  descendant — refused.
- **Locations are just containers with coordinates** — an item without its
  own pin inherits the nearest ancestor's (`/locations` page; effective
  coordinates walk the chain in one recursive CTE).
- **Tags** — key or key=value, searched by existence, glob, or regex.
- **Search** — the items page filter, backed by the BFF view
  (`GET /api/v1/views/items?query=…`), one round-trip per screen.

## 2. The physical link: a QR code on every object

- Any item's page serves its QR: `GET /api/v1/items/{id}/qr.png` — a real
  PNG encoding `$INVENTORY_QR_BASE_URL/i/{ulid}`.
- **Scan it with any phone camera** — the browser opens `/i/{ulid}` and
  lands on the item. No app required. (The URL prefix is deployment config;
  the ULID is the identity — [deploy/DEPLOYMENT.md](deploy/DEPLOYMENT.md)
  "The public base URL, and moving hosts".)
- **Foreign markers**: attach an NFC UID, a product UPC, or someone else's
  QR to an item as an identity — scanning that marker resolves to the item
  too. A marker reused on a second item is refused loudly, never silently
  re-pointed.

## 3. Print a real label (the hardware moment)

Wake the printer, confirm the stock, then:

```sh
just print-label <item-id>     # POST …/print-label, returns 202; the worker prints
```

Talking points while it prints: tape-width-aware formats (12 mm standard,
24 mm large, 9 mm tiny carries a bare ULID because a URL won't scan at that
size), real Brother raster-protocol bytes over TCP 9100 (a Zebra/ZPL path
exists too — mention it, but the Zebra stays home; this demo prints on the
Brother only), and the print is **audited and published** like every other
mutation. Scan the fresh label back to close the loop.

### Printer travel kit — getting the Brother onto the venue network

Pack: the PT-P750W, its **AC adapter** (wireless is disabled on AA
batteries), spare tape at the widths you'll show, and a USB cable (the
Windows Printer Setting Tool over USB is the fallback if the web route
fails).

Ask the AV contact, ideally before arriving:

1. Is the Wi-Fi **WPA2-PSK** (a shared password)? The printer cannot join
   WPA2-Enterprise.
2. Is **client isolation off** on that SSID? Isolation silently blocks
   laptop → printer port 9100 while both look "connected".
3. Does the SSID exist on **2.4 GHz**? The P750W is 2.4 GHz-only.

At the venue — about 3 minutes, BEFORE going live (the screencast drops
while the laptop is off the venue network):

1. AC power; hold **Wireless Mode** ~1 s until the Wi-Fi lamp lights.
2. The Mac joins `DIRECT-brPT-P750W****` (last four of the serial — label
   under the cassette cover), password `00000000`.
3. The printer is that network's gateway, so its address is simply:
   `ipconfig getoption en0 router`
4. Browse `http://<that-ip>/` (login: the **Pwd** sticker in the media
   compartment) → Network settings → venue SSID + password, interface
   mode "Infrastructure and Wireless Direct".
5. The Mac rejoins the venue Wi-Fi; the printer follows on its own.
6. Find its new address:
   `dns-sd -B _pdl-datastream._tcp local.` (the port-9100 service
   announces itself), or long-press **Feed & Cut** (prints the settings
   report — costs a little tape), or ping-sweep the subnet and
   `nc -z <ip> 9100` the live hosts.
7. Prove it and wire it in, then print ONE private rehearsal label:

   ```sh
   nc -vz <printer-ip> 9100
   # .env — numeric IP: the print worker runs in a container, where
   # mDNS .local names do not resolve
   INVENTORY_PRINTER_HOST=<printer-ip>
   just print-label <item-id>
   ```

## 4. Create an item from a barcode

`/items/upc` page: type (or scan) a product's UPC. The catalog lookup
(`GET /api/v1/catalog/upc/{gtin}`) pre-fills the item — name, photo — and
one confirm creates the item with the UPC already attached as its marker
and the photo as its asset. Re-scanning the same product later resolves to
the item you already have.

## 5. Photos you can carve items out of

On an item with a photo: the **SpaceAnnotator** island (Svelte, compiled
into the app). Draw a rectangle around something in the photo — a box on a
shelf, a tool in a drawer — and **make-item** turns the region into a new
item contained in the photographed one
(`POST /regions/{id}/make-item`). Cataloging a messy shelf becomes:
photograph it once, then point at things.

## 6. Nothing happens unnoticed

- `/audit` page: every mutation, with who did it (per-request principal),
  what, when, and the details payload.
  `GET /api/v1/audit/target/{id}` shows one item's whole history.
- **The live fact stream**: `GET /api/v1/events/stream` (SSE) — keep a
  terminal open with it during the demo; every create, move, tag, print,
  and data operation announces itself the moment it commits, carrying the
  same event id as its audit row. The projector at `:8083` is a consumer of
  exactly this plane.

## 7. Data media: what's on your discs, and where else it lives

The Phase 23 star. Full commands in [RUNBOOK.md](RUNBOOK.md) "Hashing a
data medium" — the demo shape:

1. Make an item a data medium, then **describe** a directory tree into it
   from plain `find` output (sizes + paths, no reading of content):

   ```sh
   find ~/some-tree -type f -printf '%s\t%TFT%TT\t%p\n' > manifest.tsv
   curl -X PUT --data-binary @manifest.tsv -H 'Content-Type: text/plain' \
     -H "Authorization: Bearer $TOKEN" localhost:8081/api/v1/items/$ITEM/data/manifest
   ```

   Structure-level duplicate detection works **immediately**, before any
   byte is read. Archives in the tree become items of their own.
2. **Hash** it with the standalone worker (`inventory-hasher hash --item
   $ITEM --root …`) — claim-based, restartable, kill it mid-run and start
   it again: nothing hashed twice, nothing skipped. `progress` prints the
   one-line progress bar the schema keeps for free.
3. Then ask the three questions, over plain HTTP:

   ```sh
   curl "$API/api/v1/data/sections?match=structure"   # duplicated sections, whole inventory
   curl "$API/api/v1/items/$ITEM/data/overlap"        # how much of this medium is elsewhere
   curl "$API/api/v1/items/$ITEM/data/repairs"        # what it could not read — and who has an intact copy
   ```

   `match=merkle` finds relocated-but-identical subtrees;
   `match=content` finds renamed-but-identical ones; damaged media compare
   as equal only when identically damaged — by construction.

**Talking point, real numbers**: the measurement run over the owner's
120 TB medium — 131.5 M paths, 1.4 PB logical — found **81,513 duplicated
sections (~19.3 TB) inside a single snapshot generation**
(`inventory-impl-root/inventory-impl-pg/src/test/resources/measurements/results/`).

**Scope honestly**: demo with a modest tree (tens of thousands of files —
the 80k-entry real manifest ingests in ~14 s). The 120 M-line manifest
waits on streaming ingest ([TODO.md](TODO.md) item 4), and the full
catalog-the-real-medium run is queued as item 5.

## 8. The iOS app

`just ios-build` (or `just ios-open` and run from Xcode on a simulator or a
provisioned phone). Scan any printed label — the parser is host-agnostic,
so labels printed under any base URL resolve. NFC reading is designed but
gated on the Apple Developer enrollment — don't promise it live.

## 9. The ops story (for a technical audience)

- `/admin` — users; `/tokens` — API bearer tokens, issued and revoked.
- Day-2, live and unrehearsed if you're brave
  ([RUNBOOK.md](RUNBOOK.md) drills):

  ```sh
  just backup                    # pg_dump, timestamped
  just drill-warm                # bounce the server; data survives
  just destroy && just restore <file> && just smoke   # the resurrection
  just migrate                   # idempotent; run it twice to prove it
  ```

- Under the hood, one sentence each: every mutation is one transaction that
  includes its audit row; the same storage contract runs on Postgres and
  in-memory, held identical by a parity TCK; facts publish after commit
  with the audit row's own id; the whole stack builds to native images and
  releases from a git tag (`-Drevision`).

## Known warts — don't demo these

- The QR base-URL default points at the API port, which doesn't serve
  `/i/` — set `INVENTORY_QR_BASE_URL` to the web-app's public URL before
  printing anything you'll scan on stage ([TODO.md](TODO.md) item 2).
- Giant manifests (the 29 GB find output) — streaming ingest isn't built
  yet (TODO item 4).
- Android (deferred, no device) and iOS NFC (Apple enrollment).
- Tenancy is schema-only as of 2026-08-31 (PLAN.md Phase 27) — one shared
  inventory today; don't promise per-person inventories yet.
