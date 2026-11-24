# AGENTS.md — working conventions for AI agents

Read this before touching the repo. It encodes the testing posture, the
fast loop, and the rules that make the app safe. CLAUDE.md has the
architecture and the hard constraints — this file is about *how we prove
it works*. Nothing here weakens a hard constraint; it adds the proof bar.

## The gate, every time

```bash
just fast    # ~5s — lint + tests. Run while you iterate.
just check   # ~6s warm — lint + tests + full simulator build. Run before you commit.
```

`just check` is the merge bar. No exceptions — no "just this file", no
"the build is fine, skip the tests". When in doubt, run it. It is seconds
warm; the first cold build takes a few minutes.

What each piece does, honestly:

| Target | Time | Catches |
|---|---|---|
| `just lint` | ~0.5s | swift-format strict violations across `App/` and `VampireCore/` |
| `just test` | ~4s | every VampireCore unit suite + the fake-camera tool tests (172 Swift + 8 Python tests, all must pass) |
| `just build` | ~2s warm | full SwiftUI/UIKit build for the iOS Simulator (generic destination — the named iPhone 16 Pro destination fails on this machine) |
| `just check` | ~6s warm | all of the above |
| `just test-tools` | ~0.1s | fake camera alone (protocol, reads, never-delete refusal) |

`just format` re-formats in place. Never hand-edit formatted files into a
shape the linter will reject.

## What is covered — and what is not

**Covered (unit, no device):** RAW/IFD/MakerNotes parsing (ARWHeadParserTests,
FujiParserTests, DisplayOrientationTests, EmbeddedImageLocatorTests); the
PTP/IP wire layer (PTPCodecTests, SonyContentsTests, CameraShotTests); the intent log + apply plan (IntentLogTests incl.
ApplyPlanTests); burst clustering + cull order + pager state (BurstClusteringTests,
CullOrderTests, PagerPositionTests, PagerSimulationTests); the windowed
loader + scheduler (WindowedLoaderTests, RequestSchedulerTests); index
storage + signals (IndexStoreTests, SignalAnalysisTests); pager simulation
against scripted repros + 400 seeded sessions; the fake camera's own
contract (`tools/test_fake_a7rv.py`: handshake, listing, reads, reconnect
re-read, and the never-delete refusal).

**Not covered (be honest about this):**

- **Photos API behavior** (`PHPhotoLibrary` fetch/changes) — ignored
  deliberately. There is no sandbox for the Photos framework; do not write
  tests that pretend otherwise. This is a known gap, not a passing test.
- **Vision** (faces, quality, feature prints) — device-only; the
  simulator has no Neural Engine. `VisionAnalyzer` degrades gracefully
  without it.
- **Full-resolution RAW decode**, real camera performance, the UI feel —
  manual, device-only.
- **Real camera sessions** — the fake camera (`tools/fake_a7rv.py`) stands
  in; it covers the protocol contract, not the physical hardware.

## Repro-first, every fix

When you fix a bug, the repro comes first:

- Pager/loading/culling state bug → a `PagerSimulationTests` scenario
  (scripted repro or a seeded invariant check). Never fix in SwiftUI.
- Pure logic (parsing, clustering, intent log, index, camera shot, signals)
  → a unit test in the owning suite.
- Fake-camera behavior → `tools/test_fake_a7rv.py`.
- Only then write the fix. If the fix can't be reproduced in the harness,
  it's probably UI/device — say so in the PR/commit, don't hide it.

## The fake camera — where it earns its keep

`tools/fake_a7rv.py` serves a card (`tools/make_fake_card.py`) over PTP/IP
and stands in for the real camera in the simulator: it re-reads `card.json`
per connect (new shots join, removed shots drop out) and refuses every
destructive op with OperationNotSupported — never `DeleteObject` (0x100B),
never content delete (0x9250). It is used by the DEBUG smoke flow, not by
the unit gate — but its own tests run in `just test`.

DEBUG smoke flow (the smoke test, not the gate): reinstall the app →
rewrite the UserDefaults plist (`camera.ip`, `demo.openCamera`, optional
`demo.pagerIndex`) — the container ID changes on reinstall — relaunch →
verify the grid renders and the pager opens → check `camera-log.txt`.
The plist is read once at launch; do not assume it survives reinstall.

## Hard constraints (do not violate — see CLAUDE.md for the full text)

1. Never delete assets incrementally — cull decisions go into the append-only intent log; deletion is batched at Apply. One dialog per session.
2. Never decode full-res RAW on the scroll/critical path — grid/pager use embedded previews + ImageIO-downsampled images; full `CIRAWFilter` decode is Inspect-only.
3. Never pull original bytes to read metadata — parse the ~1MB head via `requestData`, cancel the request.
4. The culling UI reads from the local index, never Vision/RAW synchronously.
5. `PHAsset.localIdentifier` is the join key.
6. `PHAsset.burstIdentifier` is insufficient — clustering is ours.
7. Never gate the UI on indexing completion.
8. Never delete anything on the camera — 0x100B/0x9250 stay refused, in the app and in the fake.

## Conventions

- Swift, SwiftUI shell, `UICollectionView` where scroll perf needs it.
- GRDB for SQLite; migrations explicit and versioned.
- Background work off the main actor; UI state updates back on `@MainActor`.
- Value types for index records; the store is the source of truth.
- Destructive PhotoKit code isolated in one module with a dry-run mode.
- Fixtures live in `fixtures/` (tracked in git). Adding a layout assumption → add the fixture + the exiftool dump. `RealFixtureTests` skips cleanly when fixtures are absent so the gate stays green on any machine.
