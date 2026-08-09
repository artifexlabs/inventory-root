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
