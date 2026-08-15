# Ongoing feature ideas

A numbered backlog of feature ideas, separate from PLAN.md's phases. Each entry
keeps its number FOREVER (numbers are never reused or renumbered; the one-time
reorder below happened 2026-08-09, before any work started) so work can be
invoked by saying e.g. **"add ongoing item 2"** — at which point the idea gets
worked into PLAN.md properly (phase/milestone, design, tests) and its box gets
checked here with a date and a pointer to where it landed.

Items 1–3 are one design cluster in dependency order: locations joining the
containment model (1) is the foundation that makes picture-locations (2) and
map-drawn locations (3) fall out of the Phase 8 region machinery almost for
free. Item 4 is standalone.

- [ ] **1. Location as a container type** — model a location as a type of
      container, unifying the "what holds what" hierarchy (items in containers in
      locations) under one containment model. *Foundation for 2 and 3.*
- [ ] **2. Picture-as-location** — upload a picture that IS a location (not just
      an asset attached to an item), which can then hold containers. *Builds
      on 1.*
- [ ] **3. "Map" asset type** — an asset kind on which boxes are drawn (same
      annotator mechanics as Phase 8) but the boxes become LOCATIONS rather than
      items — e.g. a floor plan or garage photo marking out named places.
      *Builds on 1; pairs naturally with 2. `makeItemFromRegion` gains a
      location-flavored sibling.*
- [ ] **4. "Heavy" flag on items** — a checkbox data element denoting an item is
      difficult to move. Does NOT replace weight (`weightGrams` stays); this is a
      human judgment ("two-person lift", "don't bother relocating"), not a
      measurement. *Standalone; can land any time.*
- [ ] **5. Add tags to things** - a tag is a metadata markup on an object
      that may or may not have an associated value.  For instance, there might
      be a tag called "scuba" and there might be a tag called "color" with
      the value "orange".  The first would be rendered as "scuba" and the second
      would be rendered as "color=orange".  We should be able to search things
      based on tags, either the simple existence or matching a glob or regex pattern
- [ ] **6. Data items are distinct from physical items** - This is already partially
      true, but there should be some sort  of container that is a network share mount
      or a CD or DVD or other removable medium that describes the contents of that
      medium using hashes and relative paths.  This would be rendered very differently
      than physical items, although the physical object that contains the data would
      definitely need to be called out as a physical item.  This is already started with
      DataInfo
- [ ] **7. Physical identifiers: QR, UPC, and NFC tags** - We should lookup default
      information about items that we add by scanning UPC codes or perhaps some sort of
      QR code. *(NFC assessed and folded in 2026-08-14.)* All of these are one problem
      underneath — a physical marker resolving to an item — so build ONE
      `item_identities(kind, value) -> item_id` mapping (kind = `nfc-uid` | `upc` | ...),
      the same shape as Phase 13's `user_identities(provider, subject)`, rather than a
      bespoke column per marker type. On the bus fabric that is a changeset, one
      BusActions entry with its role, a verticle handler, and a gateway route. Separately,
      UPC also wants an external catalog lookup to prefill metadata for a new item.
      *Shares its storage with 12: build the identity table once and NFC gets its half
      free — do NOT add a bespoke `nfc_uid` column.*
- [ ] **8. Dots as items on photos** - We should be able to just point at a spot on a photo
      and, without actually drawing a box, denote an item.
- [ ] **9. AI assistance in cataloging** - We should be able to use an AI cli tool to point 
      an LLM at a photo of things and have it build a set of items as descriptions.  It should 
      also be able to update an existing item with corrected or additional metadata if we 
      use a mobile device's camera on an existing thing.  We would definitely not want to 
      use some sort of service that requires us to pay per-transaction.  It would need to be
      used via a CLI or something that lets
- [ ] **10. Add a switch to turn on Chain-print labels** - This would allow Brother labels to 
      be more easily and efficiently utilized.  IT would also need an "extend the tape" button.
- [ ] **11. Create a small Brother QR Code** - Make the smallest possible QR code for an object
      so that we could just attach the QR code to something very small.  The QR code should reference
      just like the original one, but it's possible that we could make one slightly smaller that
      the phone camera could still scan.  That will need experimentation.
      *(Arithmetic worked 2026-08-14.)* At 180 dpi one dot is 0.141mm, and
      `BrotherPTouchPrinter.TAPE_DOTS` already has the printable band per tape:
      24mm=128 dots (18.1mm), 18mm=112 (15.8mm), 12mm=70 (9.9mm), 9mm=50 (7.1mm),
      6mm=32 (4.5mm). Two dots per module (0.28mm) is the practical floor for a phone
      camera; one dot (0.14mm) is hopeless and thermal bleed merges it. Today's proven
      24mm label runs ~3 dots/module (0.42mm).
      **6mm and 3.5mm are impossible**: the smallest QR that exists is version 1 at 21
      modules = 42 dots at the floor, and 6mm gives 32. (Micro QR M1 is 11x11 but holds
      5 numeric digits and scans poorly — not an escape.)
      **The payload is the lever, not the printer.** Today's `http://host:8081/i/{ulid}`
      (~50 bytes) forces version 3 = 29 modules, plus zxing's default 4-module quiet
      zone = 37 printed. Three tiers: short URL -> v3/29 modules (fits 12mm at 2 dots =
      8.2mm); bare 26-char ULID -> v2/25 modules, and because ULIDs are Crockford base32
      they encode in ALPHANUMERIC mode, fitting v2 even at ECC Q (fits 9mm at 2 dots =
      7.06mm exactly); raw 16 ULID bytes in byte mode -> **v1/21 modules**, which on 12mm
      at 3 dots/module is an 8.9mm code at the already-proven 0.42mm module size. Note
      the inversion: the v1 code on 12mm is physically BIGGER than the v2 code on 9mm but
      far more robust — smallest tape and smallest reliable QR are different targets.
      Cost of the last two tiers: a bare ULID is not a URL, so a generic camera app shows
      gibberish and only our own scanner resolves it.
      **Three code changes needed**, first one is the blocker: (a) `LabelComposer` does
      `drawImage(qr, 0, 0, heightDots, heightDots)` — an arbitrary rescale that at 128
      dots / 37 modules emits a mix of 3- and 4-dot modules; it survives only because the
      modules are big, and is fatal at 50 dots. Render at an exact integer dots-per-module
      and center. (b) `QrCodes` uses zxing defaults, printing the quiet zone inside the
      square — set `MARGIN=0` and let the unprinted white tape supply it, worth 8 modules.
      (c) small tapes need a QR-only layout; at 50 dots the ID font computes to ~7px.
      *Do this WITH 10: P-touch wastes ~25mm of leader tape per cut, so a 9mm label still
      costs ~34mm and shrinking the label saves nearly nothing until chain printing
      amortizes the leader across a run.*
- [ ] **12. NFC Reading** - A given NFC tag could be associated with an object instead of
      or in addition to some other type of label. *(Assessed 2026-08-14; the storage
      mechanism lives in 7.)* About a day of code per platform. Android is free and
      unblocked (NFC permission + `enableReaderMode()`); iOS Core NFC needs the
      reader-session entitlement and therefore the PAID Apple Developer account that
      Phase 13 already requires — there is no simulator NFC, and iPads have no NFC radio
      at all, so the universal app must degrade via `readingAvailable`. Do both bindings:
      write the same `/i/{id}` URL the QR encodes (a ~45-byte ULID URL fits a $0.15
      NTAG213 with room to spare — the ULID compactness argument again) AND record the
      tag's factory UID, which keeps working on blank or write-locked tags and catches a
      tag reused on a second item. Hardware: neither the Brother nor the Zebra can encode
      NFC, and Zebra's RFID printer-encoders write UHF that phones physically cannot
      read — so it is print the label, then tap-program a separate NTAG sticker, two
      physical actions. Metal detunes NFC (tools and steel shelving need pricier
      ferrite-backed on-metal tags), and the 1-4 cm range makes NFC a complement to QR
      rather than a replacement (NFC wins in the dark, with no line of sight, on scuffed
      labels; QR wins at distance). Not CI-testable; manual hardware smoke like the
      printer. *Builds on 7's `item_identities` table. Naming: always spell out "NFC
      tag" — bare "tag" now means item 5's metadata markup, and "label" means the
      printed thing.*