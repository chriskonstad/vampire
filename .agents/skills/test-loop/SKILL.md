---
name: test-loop
description: Run the Vampire test loop — lint, unit tests, simulator build — and apply the repro-first rule for fixes. Use when iterating on VampireCore logic, the pager, intent log, clustering, signals, or the fake camera.
---

# Vampire test loop

The gate is `just check` — run it before every commit. `just fast` is the
iteration loop. See **AGENTS.md** for the coverage map and the full
conventions; this skill is the battery.

## Commands

```bash
just fast          # lint + tests, ~5s warm
just check         # lint + tests + full simulator build, ~6s warm
just lint          # strict swift-format over App/ and VampireCore/
just test          # SwiftPM suites (VampireCore) + fake camera Python tests
just build         # full build, generic iOS Simulator destination
just test-tools    # fake camera contract tests alone, ~0.1s
```

- `just build` uses the **generic** `platform=iOS Simulator` destination —
  the named "iPhone 16 Pro" destination fails on this machine.
- Warm `build/DerivedData` makes `just check` seconds; cold takes minutes.

## Repro-first, every fix

Add the repro **before** the fix:

- Pager/loading/culling-state bug → `VampireCore/Tests/PagerSimulationTests/`
  scenario (scripted repro or seeded invariants). Never fix in SwiftUI.
- Pure logic → the owning VampireCore suite.
- Fake camera → `tools/test_fake_a7rv.py`.

If the fix can't be reproduced in the harness, it's UI/device — say so in
the commit, don't hide it.

## What is covered — and not

- **Covered:** parser (ARW/Fuji/MakerNotes), PTP/IP wire layer, intent log
  + apply plan, clustering + ordering + pager state, windowed loader +
  scheduler, index storage + signals, pager simulation (seeded), fake camera.
- **Not covered, deliberately:** Photos API behavior (no sandbox — do not
  fake it), Vision (device-only, sim has no Neural Engine), full-res RAW
  decode, UI feel, real camera hardware (the fake covers the contract).

## Fixtures

`fixtures/` holds real A7RV RAWs (tracked in git); `RealFixtureTests`
skips cleanly when absent so the gate stays green on any machine. No new
fixture assumption without an exiftool dump.

## Debug loop

Use the simulator, not a device. DEBUG builds carry the smoke hooks
(`demo.openCamera`, `demo.pagerIndex` in the container's `UserDefaults`
plist — rewritten after reinstall, plist read once at launch). The fake
camera (`tools/fake_a7rv.py`) serves a card over PTP/IP; it never deletes.
