# SPEC — Sony RAW Culling App (iOS)

## What this is

A fast, single-platform iOS app for **culling Sony RAW (ARW) photos that already live in the Photos library**. The user imports a shoot from a card reader (or wherever), opens the app, and rips through hundreds-to-thousands of frames deciding keep / reject / maybe — with the affordances a photographer actually needs: faces surfaced and quality-ranked, the camera's autofocus point drawn on the image, bursts and near-duplicates bundled, and instant non-destructive undo.

Explicitly **not** in scope (v1): editing/develop, cloud sync, Android.

**Wireless field culling (v2, in progress — scope reversed Oct 2026).** The app
now also talks to the camera directly over Wi-Fi (Sony A7RV) to cull *before*
anything hits the phone's library: browse the card, pull only the embedded
preview JPEGs to decide keep/reject, and import full RAWs for keepers only —
rejects are never touched on the card (we never issue PTP DeleteObject). This
is a transport project layered under the existing culling UI:

- **Transport:** PTP/IP (Picture Transfer Protocol over IP) over the camera's
  Wi-Fi. No official Sony iOS SDK exists; the client is ours, built on the
  `PTP` package codec (framing, operations, data phase, handshake — all unit-
  tested without a camera). Joining the camera's Wi-Fi uses NEHotspotConfiguration;
  the PTP socket is pinned to the Wi-Fi interface (`requiredInterfaceType`).
- **Preview without the RAW:** `EmbeddedImageLocator` finds the ARW's embedded
  JPEG ladder (thumbnail / ~1616×1080 preview / full) from the IFD tags in the
  head. The wireless path pulls ~64KB via `GetPartialObject` to locate the
  preview, then transfers only that ~344KB range — same head-parse-then-stop
  discipline as hard constraint 3, now over the wire.
- **Everything else is reused:** faces/aesthetics/AF HUD run on the pulled
  preview exactly as on a library asset; keeps import via `PHAssetCreationRequest`.
- **Live transport needs on-device iteration** against the real camera; it
  cannot be verified in the simulator (no Wi-Fi join, no camera).

The old "reads from the Photos library, never talks to the camera" model still
works and remains the path for card-reader imports.

## North-star UX

Open app → shoot is browsable in under a second (thumbnails + time-clusters) while deeper indexing streams in behind it → swipe through full-screen previews with the AF point overlaid → one-tap keep/reject → faces and best-of-burst surfaced automatically → one "Apply" at the end commits all rejects in a single batch. Never a stutter on scroll, never a full-res decode on the critical path.

## Core architecture

The whole design rests on one idea: **a one-time background indexing pass** that extracts everything expensive (faces, AF box, similarity feature prints, quality scores, head-of-file EXIF/MakerNotes) into a **local persistent store** keyed by `PHAsset.localIdentifier`. The culling UI then reads only from that store plus cheap rendered previews. The UI never parses a RAW or runs Vision on the critical path.

```
Photos library (PHAsset, RAW UTIs)
        │
        ▼
Indexing pass (background, resumable)
   • head-of-file stream read → EXIF + Sony MakerNotes (AF box, face frames)
   • Vision on ~1024px preview → face rects + capture-quality scores
   • Vision feature print → similarity / dedup
   • time + visual clustering → burst groups
        │
        ▼
Local store (SQLite via GRDB), keyed by localIdentifier
        │
        ▼
Culling UI  ←  PHCachingImageManager (previews)  +  intent log (keep/reject/maybe)
        │
        ▼
Apply  →  single batched PHPhotoLibrary.performChanges
```

### Two access tiers per asset

- **Rendered preview** via `PHImageManager` / `PHCachingImageManager`. For ARW, Photos serves the embedded preview JPEG — cheap, no RAW decode. This is what the grid and pager show.
- **Original bytes** via `PHAssetResourceManager.requestData`, which **streams in chunks**. Used only during indexing. EXIF + Sony MakerNotes live in roughly the first ~1MB of the ARW, so we read the head of the stream, parse, and cancel the request — we never pull the full 60–130MB file just to read a focus box.

## Features

### AF point overlay (the killer feature)
Sony bodies of the A7RV generation write the active AF point into MakerNotes. exiftool exposes it as **`FocusLocation`, Sony tag `0x2027`** — four integers encoding image width/height plus focus X/Y. Newer bodies also carry face-frame info. ImageIO will **not** parse MakerNotes, so we port the relevant slice of exiftool's Sony tag table — a small, well-documented binary IFD parse. Tag presence/layout varies by model, firmware, and drive mode, so **validate against real fixture files first** (`exiftool -a -G1 -Sony:all sample.ARW`).

UI: draw the AF point as a normalized-rect overlay on the preview, plus a one-tap "zoom to AF point at 100%" gesture — the fastest possible sharpness check.

### Faces, surfaced and quality-ranked
Photos' own face database is not API-accessible, so we run Vision during indexing:
- `VNDetectFaceRectanglesRequest` → face crops to show in a strip at the top.
- `VNDetectFaceCaptureQualityRequest` → a per-face quality float (sharpness/eyes/expression). This powers "faces sorted by quality" and "best face in this burst" badging — not just "faces exist."

Run on ~1024px previews, not full res. Fast, and the scores hold up.

### Burst / similar grouping
`PHAsset.burstIdentifier` only covers iPhone-native bursts, so camera imports need our own clustering (which works better anyway). Two layered signals:
- **Time:** group assets whose consecutive `creationDate` deltas fall under a threshold (~1–2s catches ~10fps drive bursts; ARW EXIF has subsecond precision).
- **Visual:** `VNGenerateImageFeaturePrintRequest` per asset. Feature-print distance splits a time cluster when the scene changed mid-burst, and merges "walked around the subject" sequences. Feature prints are tiny — store them in the index and global "find similar" comes for free.

### Do / undo / apply (non-destructive by default)
Every `PHPhotoLibrary.performChanges` deletion fires a **system confirmation dialog**, so we never delete incrementally. Instead:
- Culling produces a **local append-only intent log** (keep / reject / maybe per asset). Append-only makes undo/redo trivial and sessions resumable across launches.
- A single **"Apply"** commits all rejects in one batched `deleteAssets` call → one dialog. Deletions land in Recently Deleted (30-day safety net) regardless.
- Keeps map to `isFavorite = true` and/or an album add, also batched.

### Scroll smoothness
- `PHCachingImageManager` with `startCachingImages`, driven by `UICollectionViewDataSourcePrefetching`.
- Request `.opportunistic` so a degraded thumb appears instantly then refines.
- Full-screen pager: decode at screen scale via ImageIO downsampling (`kCGImageSourceThumbnailMaxPixelSize`) — never decode 61MP to fill a 2K screen.
- `NSCache` of decoded images for ±3 neighbors.
- Reserve actual `CIRAWFilter` RAW decodes for an explicit "inspect" action only.
- Same priority-queue scheduler concept throughout: **current > next > prev > prefetch**.

## Tech stack

- Swift, SwiftUI for shell + UIKit `UICollectionView` where prefetching/scroll perf demands it.
- PhotoKit (`PHAsset`, `PHImageManager`, `PHCachingImageManager`, `PHAssetResourceManager`, `PHPhotoLibrary`).
- Vision (face rects, face capture quality, feature prints).
- ImageIO + Core Image (`CIRAWFilter`) for decode/downsample.
- GRDB (SQLite) for the index + intent log.
- Custom Sony MakerNotes IFD parser (ported subset of exiftool's Sony table).

## Build order (de-risk first)

1. **MakerNotes / `FocusLocation` parser** — riskiest unknown (tag layout varies by firmware), and the AF overlay depends on it. Pure logic, TDD against ARW fixtures. **Do this first.**
2. **Intent log + undo/redo** — pure logic, unit-tested.
3. **Burst clustering + feature-print similarity** — pure logic + Vision, tested against fixtures.
4. **PhotoKit fetch + preview pipeline + caching scheduler** — needs simulator/device with a real library.
5. **Culling UI: grid, full-screen pager, AF overlay, face strip** — device feel work.
6. **Apply / batched deletes / favorites** — device, careful with the destructive path.

Make the UI usable immediately on time-clusters + thumbnails while index results stream in and re-sort. Never gate entry on a progress bar.

## Prerequisites / entitlements
- Apple Developer account (paid needed for device deployment; the perf work only means anything on hardware).
- `NSPhotoLibraryUsageDescription` from day one.
- Photo library access (read + the delete/modify path for Apply).

## Open design questions (for discussion, not yet decided)
- How do "maybe" piles interact with burst groups? (per-frame vs per-group state)
- Best reject gesture (swipe direction, edge, two-finger)?
- Default burst time threshold and whether it should adapt to detected drive mode.
- Whether to expose feature-print "find similar" globally in v1 or hold for v2.
