# UPC catalog lookup — staged work plan

*Written 2026-08-16 (sources researched and decisions taken the same day). This is
a STAGING document: when the UPC work is scheduled — possibly next — this plan
moves into [PLAN.md](PLAN.md) as a proper milestone and this file retires.
Completes ongoing item 7's deliberately deferred tail: the external catalog
lookup that prefills metadata for a new item from a scanned UPC.*

## What already exists (item 7, shipped 2026-08-15)

The identity machinery is done: `item_identities(kind, value) → item_id`
(kind `upc` included), claim/release/resolve over the bus, and
`GET /api/v1/items/by-identity?kind=upc&value=…`. The iOS scanner (same day)
already resolves QR deep links and bare ULIDs. This work adds: **UPC/EAN
symbologies in the camera scanner, an external catalog lookup, and a one-shot
create-item-from-UPC flow that acquires as much relevant information as
possible, including a stable link to the outside source.**

## Decisions (locked 2026-08-16)

| Decision | Choice | Rationale |
|---|---|---|
| Catalog sources | **Both, open-data first**: Open Food Facts family, then UPCitemdb trial | ODbL open data preferred; UPCitemdb's ~722M codes cover the general merchandise (tools, household) the OFF family misses. Each source is a config-gated adapter. |
| Product image | **Attach + link**: download the catalog image once at creation, attach as a normal asset; tag the item with the stable source URL | Survives the external site changing; the link satisfies ODbL attribution and gives a durable outside reference. |
| Default | **On** (`inventory.catalog` defaults to the full source list) | Free and keyless, so scanning works out of the box; `off` remains a config choice. Tests never touch the network (stub HTTP fixtures). |

## Catalog sources (researched 2026-08-16)

| Source | Coverage | Access | License | Stable link | Useful fields |
|---|---|---|---|---|---|
| **Open Food Facts family** — world.openfoodfacts.org, world.open**products**facts.org, world.open**beauty**facts.org, world.open**petfood**facts.org | food strong; general/beauty/pet-food thinner | REST, **no key, no metering**: `GET https://world.<flavor>.org/api/v2/product/{barcode}.json` (`?fields=` narrows the response) | **ODbL** (database), DbCL (contents), **CC-BY-SA** (images) — attribution + share-alike | `https://world.<flavor>.org/product/{code}` | `product_name`, `brands`, `generic_name`, `quantity` ("330 ml"), `product_quantity` + `product_quantity_unit`, `categories`, `image_url` |
| **UPCitemdb** — upcitemdb.com | ~722M codes; strongest for general merchandise | free **trial tier, no key**: `GET https://api.upcitemdb.com/prod/trial/lookup?upc={code}` (~100 lookups/day; paid tiers exist but nothing forces pay-per-transaction) | commercial, as-is, no guarantees | `https://www.upcitemdb.com/upc/{code}` | `title`, `brand`, `description`, `category`, `images[]`, `dimension`, `weight`, recorded price range |
| GS1 "Verified by GS1" — verified.gs1.org (replaced GEPIR end-2023) | authoritative registry (the issuer itself) | web lookup **free**, ~30/day per IP, unauthenticated; **no documented free API** — programmatic access is paid (e.g. GS1 US Data Hub, ~$500/yr) | GS1 terms | `https://www.gs1.org/services/verified-by-gs1/results?gtin={code}` | brand, product description, GPC category, net content, company of record, sometimes image. **NO ADAPTER for now**: an adapter would ride the web UI's undocumented endpoint (fragile, ToS-questionable). Useful as a MANUAL verification fallback; revisit if GS1 opens a public API |
| upcdatabase.org | community, small | keyed API | community | yes | thin — not worth an adapter now |

**Attribution note (ODbL/CC-BY-SA):** the `source=<url>` tag on every
catalog-created item, plus this document, is our attribution to the Open Food
Facts projects. If catalog data is ever redistributed beyond this private
system, revisit share-alike obligations.

## Field mapping (catalog → our model)

| Catalog | Ours | Notes |
|---|---|---|
| product_name / title | `name` | trimmed |
| brand + name | `displayName` | "DeWalt 20V Drill" style |
| generic_name / description | `description` | |
| categories / category | tag `category=<x>` | catalog metadata, not our `type` — `type` stays the user's choice in the create sheet (default `thing`) |
| product_quantity+unit / weight | `weightGrams` | best-effort parse; absent on failure |
| image_url / images[0] | downloaded once → **asset** (`kind=photo`) | fetched server-side at creation, never hot-linked |
| brand | tag `brand=<x>` | searchable via the tag machinery |
| product page URL | tag `source=<url>` | the stable outside link |
| the GTIN itself | identity `(upc, <gtin13>)` | existing item 7 machinery; 409 on marker reuse |

## Implementation stages

1. **GTIN normalization (impl).** `Gtin` utility beside `QrCodes`: check-digit
   validation; canonicalize UPC-A (12), EAN-13 (13), EAN-8 (8), expanded UPC-E
   → **GTIN-13** (leading-zero pad) — the canonical `value` for identity kind
   `upc`. Pure function, unit-tested (valid/invalid digits, every length,
   `036000291452` ≡ `0036000291452`).

2. **Catalog seam (api + impl).**
   - api: `record CatalogEntry(gtin, name, brand, description, category,
     weightGrams, imageUrl, sourceUrl, source)` and
     `interface UpcCatalog { CompletionStage<Optional<CatalogEntry>> lookup(String gtin13); }`.
   - impl adapters (async `java.net.http`, native-friendly, `JsonObject`
     parsing): `OpenFactsCatalog` (flavors tried products → food → beauty →
     petfood), `UpcItemDbCatalog` (trial endpoint; degrades to empty on 429),
     `CompositeCatalog` (ordered, first hit wins), NOOP for `off`.
   - Config: `inventory.catalog` = `open-facts,upcitemdb` (default) |
     `open-facts` | `upcitemdb` | `off`; base-URL overrides
     (`inventory.catalog.open-facts.url`, `inventory.catalog.upcitemdb.url`)
     point tests at local stub fixtures (StubBackend / fake-printer pattern) —
     CI never touches the network.
   - Wired in both `InventoryBackendProducer`s (server + web-api), same switch
     pattern as `labelPrinter`.

3. **Bus + gateway.** New `catalog.upc` action (READ role) in `BusActions`,
   answered by a small `CatalogVerticle`; gateway
   `GET /api/v1/catalog/upc/{gtin}` → 200 entry | 400 bad check digit |
   404 not found | 503 catalog off. Lookups are reads — no audit row.

4. **One-shot creation.** `POST /api/v1/items/from-upc?gtin=&container=`
   (mirrors Phase 16's `from-photo`): resolve catalog entry + download image
   bytes FIRST (outside any transaction), then ONE transaction: create item
   (request-body fields override catalog prefill) → claim identity
   `(upc, gtin13)` (409 if the marker already claims another item) → attach
   the image asset when present → tags `brand=`, `category=`, `source=`. Audit rides the
   existing vocabulary (`item.create`, `item.identity-add`, `asset.attach`) —
   no new actions.

5. **iOS scanning.** Extend `ScanView`'s DataScanner symbologies to
   `[.qr, .ean13, .ean8, .upce]` (VisionKit reports UPC-A under ean13); new
   `BarcodeRef` parser (all-digits 8/12/13 + valid check digit → GTIN-13)
   beside `ScannedItemRef`, covered by the existing XCTest target. Flow:
   scanned GTIN → `by-identity` → found: open the item; 404: "Create from
   barcode" sheet prefilled from the catalog endpoint (editable; shows the
   image and source link) → `from-upc`. **Android: deferred** — the app is
   still a skeleton; this arrives with its real v1.

6. **Web UI (small).** "Add by UPC" form on the items page (type/paste digits
   → same prefill → create): a browser-testable surface and the manual path
   for damaged barcodes.

## Tests and gates

- `Gtin` unit tests (check digits, lengths, canonical form).
- Adapter tests against canned OFF/UPCitemdb JSON served by a local stub HTTP
  fixture; assert mapping, flavor fallback order, 429 degradation.
- Verticle + gateway e2e with a stub `UpcCatalog`: found / miss / off /
  bad-check-digit.
- `from-upc` transaction tests, memory + Pg: identity claimed, image asset
  attached, tags present, 409 on a reused marker, catalog-miss still creates
  a bare item from the request body.
- iOS: `BarcodeRef` XCTests; `just ios-build` + `just ios-test` green.
- Full reactor `mvn clean verify` green locally and in CI.
- **Manual gate:** scan a real grocery UPC on the phone → prefilled create →
  item exists with image, brand/category/source tags, and the claimed identity; rescan
  the same package → the item opens.

## Constraints (standing)

- No pay-per-transaction services. (GS1's WEB lookup is free ~30/day, but its
  programmatic access is paid and its free path has no documented API — hence
  no adapter, not because a lookup costs money.)
- Catalog outages or misses must NEVER block item creation — lookup is
  prefill, not a dependency.
- UPCitemdb trial's ~100/day is ample for a household; the adapter treats 429
  as "not found" and the composite moves on.
- External calls happen only in the catalog adapters behind the `UpcCatalog`
  seam; everything else stays stubbed and offline in tests.
