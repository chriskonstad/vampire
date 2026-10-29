# CLAUDE.md — working conventions for this repo

This file is read at the start of every Claude Code session. It encodes the non-obvious constraints of this project. **Violating the rules in "Hard constraints" will produce code that looks correct, compiles, and is wrong.** Read SPEC.md for the full architecture and rationale.

## What we're building
An iOS-only app for culling Sony RAW (ARW) photos — either already in the Photos library, or still on an A7RV card over Wi-Fi (PTP/IP, "camera sessions"). Both cull through the same session UI (`CullItem` + `CullImageProvider`). See SPEC.md.

## Hard constraints (do not violate)

1. **Never delete assets incrementally.** Every `PHPhotoLibrary.performChanges` deletion triggers a system confirmation dialog. Culling decisions go into the local append-only **intent log**; deletions are committed once, batched, at "Apply." One dialog per session, never per photo.

2. **Never decode a full-resolution RAW on the scroll/critical path.** The grid and pager use Photos' embedded preview (cheap) and ImageIO-downsampled images at screen scale. Full `CIRAWFilter` RAW decode is reserved for an explicit "inspect" action only. A 61MP decode on swipe = dropped frames.

3. **Never pull original bytes to read metadata.** EXIF + Sony MakerNotes are in the head (~first 1MB) of the ARW. Use `PHAssetResourceManager.requestData`, parse the head, **cancel the request**. Do not fetch the whole 60–130MB file for a focus box.

4. **The culling UI reads from the local index, not from RAWs or Vision.** All expensive extraction happens once in the background indexing pass and is persisted. If a UI code path is about to run Vision or parse a RAW synchronously, that's a bug — it belongs in the indexer.

5. **`PHAsset.localIdentifier` is the join key** between Photos and our store. Don't invent a parallel identity scheme.

6. **`PHAsset.burstIdentifier` is insufficient** — it only covers iPhone-native bursts. Camera imports use our own time + feature-print clustering. Don't rely on the system burst grouping.

7. **Don't gate the UI on indexing completion.** Show time-clusters + thumbnails immediately; stream index results in and re-sort. No blocking progress bar on entry.

8. **Never delete anything on the camera.** The PTP layer must never send `DeleteObject` (0x100B) or Sony's content delete (0x9250 — deliberately not even defined). Camera-session "Apply" is Import keepers: additive only; rejects stay on the card.

## Testing approach

Three tiers, build the pure ones first:

- **Pure logic (unit-tested, no device):** MakerNotes/IFD parser, intent log + undo/redo, burst clustering, feature-print distance, the scheduler queue. Iterate freely with the test loop. These live as Swift package targets.
- **Framework integration (simulator/device):** PhotoKit fetch, Vision requests, caching manager.
- **Feel (device only):** scroll smoothness, gestures, zoom-to-AF.

**Fixtures:** real A7RV ARW files live in `fixtures/`, covering single shot, ~10fps burst, eye-AF on a person, manual focus, and APS-C crop mode. Ground truth captured via `exiftool -a -G1 -v3 sample.ARW`. The parser is TDD'd against these — when adding a case, add the fixture + the exiftool dump.

## Simulator debugging (the default debug loop)

Debug in the iOS simulator, not on a personal device. Full recipe in README
("Simulator debugging"); the short version:

- **Driving the UI:** the built-in iOS Simulator control tool (tap/screenshot) works reliably; axe 1.5.2 broke when Xcode moved SimulatorKit to `SharedFrameworks`. Otherwise the `axe` CLI (brew-installed): `axe tap/swipe/touch/describe-ui --udid <UDID>`. Coordinates are points (402×874 on iPhone 16 Pro). Run `axe describe-ui` to get exact element frames instead of guessing tap targets. No pinch support; double-tap needs two `axe touch` calls within ~0.3s, which is flaky — fall back to a host-side double-click on the Simulator window.
- **Landscape:** axe injects in physical-portrait space even when rotated (`describe-ui` frames rotate, taps don't — `--label` taps miss too). Transform UI coords yourself: after ⌘→ rotation, `physical = (ui.y, 874 − ui.x)` — calibrated and verified. Rotation itself has no CLI; use ⌘←/⌘→ on the Simulator window.
- **RAW fixtures:** `simctl addmedia` rejects ARW. DEBUG builds include `DevFixtureImporter`: copy fixtures into the app container's `Documents/` (`xcrun simctl get_app_container booted app.vampire.Vampire data`), relaunch, and they import into the photo library.
- **Vision does not work in the simulator** ("Failed to create espresso context" — no Neural Engine). Faces, capture quality, and feature prints are device-only; the indexer must degrade gracefully without them. To exercise face UI in the sim, insert rows into the `face` table directly with sqlite3 against `<container>/Library/Application Support/vampire-index.sqlite`.
- **Logs:** `xcrun simctl spawn booted log stream --predicate 'subsystem == "app.vampire"'`. The intent journal and index are plain SQLite — inspect them rather than adding debug UI.

## The MakerNotes parser specifically
- Target: Sony tag `0x2027` `FocusLocation` (image w/h + focus x/y) and face-frame tags where present.
- Port the relevant slice of exiftool's Sony tag table — don't reinvent the IFD walk.
- Tag layout varies by model/firmware/drive mode. **Always validate a new assumption against a fixture before relying on it.** APS-C crop mode in particular changes coordinate framing.
- ImageIO does not expose MakerNotes — this parse is ours, on the raw bytes.

## Conventions
- Swift, SwiftUI shell, UIKit `UICollectionView` where scroll perf needs it.
- GRDB for SQLite. Migrations are explicit and versioned.
- Background work off the main actor; UI state updates back on `@MainActor`.
- Prefer value types for index records; the store is the source of truth.
- Keep destructive PhotoKit code (delete/favorite/Apply) isolated in one well-tested module with a dry-run mode.

## Camera (wireless) sessions
- Transport: `App/Camera/PTPTransport.swift` over the tested `PTP` package. Sony remote-transfer ops 0x923B–0x923E (list / read range / thumbnail+1616px screennail) keep the camera UI usable; wire layouts per alpha2go's docs/protocol.md, verified on the A7RV.
- Debug the live link from the Mac first: `tools/ptpip_probe.py <ip> --remote-transfer` (camera on home Wi-Fi in Access Point mode). On device, the connection log is in-app and in `Documents/camera-log.txt` (`xcrun devicectl device copy from … --domain-type appDataContainer`).
- Sony answers DeviceBusy (0x2019) routinely; `require()` retries it. Only transport errors count as a lost link.
- AF/face geometry is stored in upright display space (`FocusLocation.displayOriented`), for both sources.

## Out of scope (don't build speculatively)
Editing/develop, cloud sync, Android, sharing the index across devices.
