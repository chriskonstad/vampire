# Vampire 🦇

**Cull like a Cullen.** A fast, on-device photo culler for iPhone: rip
through a RAW shoot, keep only the immortals.

[Download on the App Store](https://apps.apple.com/app/id6787546955) ·
**Free — and it always will be: no subscription, no ads, no account, no tracking.**

- **Two sources, one culling screen.** Cull photos already in your Photos
  library, or **straight off a Sony camera over Wi-Fi** — previewing every
  frame without transferring the RAW, and bringing home only the keepers.
- **The camera's own AF point** (from Sony/Fujifilm MakerNotes), drawn on the
  frame.
- **Faces ranked by capture quality, with blink warnings**; aesthetic score,
  exposure clipping, horizon tilt, saliency — all Vision, all on-device.
- **Bursts stack together** (sub-second chains), with a best-frame hint and a
  one-tap "keep this one, reject the rest".
- **Nothing is deleted until you say so.** Decisions live in an undoable
  local journal; library deletes happen once, batched, into Recently
  Deleted. Camera sessions never delete anything on the card.
- **Built for iPhone Duo.** Unfolded, the whole burst lines up beside the
  frame you're judging, with larger face crops; folded, culling carries on
  on the outer screen. (The layout keys off available width, so any wide
  canvas gets it.)

## Culling straight off the camera (Wi-Fi)

Shoot RAW all day, keep everything on the card as your backup, and each
evening cull the day's shots from the phone. Vampire pulls each frame's
1616px preview, AF point and face/eye analysis over Wi-Fi (~0.15 s a frame —
never the 60 MB RAW), works offline from its cache if the camera sleeps or
drops, and imports only your keepers as full RAWs, resuming mid-file after a
disconnect. Decisions persist across reconnects and days; shots deleted from
the card drop out of the app.

### Camera compatibility

| Status | Cameras |
|---|---|
| **Tested** | Sony **α7R V** (ILCE-7RM5), firmware 3.00 |
| **Likely compatible (untested)** | Sony bodies with in-session card access over PTP/IP ("remote transfer" / background file transfer in Sony's Camera Remote SDK): α7 IV (ILCE-7M4), α6700 (ILCE-6700 — these commands are verified on it by [alpha2go](https://github.com/knallli/alpha2go)), α7C II (ILCE-7CM2), α7CR (ILCE-7CR), α7S III (ILCE-7SM3), FX3, FX30 |
| **May work (untested)** | Newer bodies on the same platform: α1 II, α9 III, α7R VI, α7 V |
| **Not supported** | Fujifilm, Canon, Nikon over Wi-Fi (Fujifilm *files* cull fine from the Photos library) |

If you try another body, please open an issue with the connection log
(Camera session → log icon → Copy).

### Setup (α7R V; similar on other recent Sony bodies)

1. **MENU → Network → Cnct./Remote Sht. → Remote Shoot Function →
   Remote Shooting: On.**
2. Connection method:
   - **In the field:** *Cnct. Method → Wi-Fi Direct*. Join the camera's
     `DIRECT-…` network in iOS Settings (password is on the camera screen).
   - **At home:** *Wi-Fi Access Point*, with camera and phone on the same Wi-Fi.
3. **MENU → Network → Network Option → Access Authen. Settings →
   Access Authen.: Off** (Vampire uses pairing; access authentication over
   SSH isn't supported yet).
4. In Vampire, tap **Camera** (top-left) → **Find & Connect**, allow Local
   Network access, and accept the pairing prompt on the camera the first
   time.

Vampire only *reads* from the camera. It never sends a delete — the
protocol layer doesn't even define Sony's delete command.

## Build & test

Requires Xcode 27.1+ (iOS 27.1 SDK — needed for native iPhone Duo rendering; deployment target iOS 26).

```sh
cd VampireCore && swift test          # pure logic: parsers, PTP codec, journal, store
xcodebuild -scheme Vampire -destination 'generic/platform=iOS Simulator' build
```

For a device, open `Vampire.xcodeproj`, set your team and a bundle ID you
own on the Vampire target, and run.

### No camera? Use the fake one

`tools/fake_a7rv.py` is a fake α7R V over PTP/IP that serves the fixtures
with the real wire layouts — enough to develop and screenshot camera
sessions in the simulator:

```sh
python3 tools/make_fake_card.py /tmp/fakecard        # --extra adds "later" shots
python3 tools/fake_a7rv.py /tmp/fakecard              # serves :15740
# Simulator: point the app at this Mac
xcrun simctl launch booted com.chriskonstad.vampire -camera.ip <mac-ip> -demo.openCamera YES
```

`tools/ptpip_probe.py <ip> --remote-transfer` is a read-only probe for a real
camera (or the fake), handy for debugging a new body.

## Layout

```
VampireCore/             Swift package — pure logic, unit-tested on macOS
  SonyMakerNotes/        TIFF/IFD walk, Sony + Fuji MakerNotes (AF point/frame,
                         faces), embedded-preview locator, display orientation
  PTP/                   PTP/IP codec + Sony remote-transfer layouts
  CullIntent/            append-only decision journal with undo/redo
  BurstClustering/       time + feature-print clustering
  RequestScheduling/     current > next > prev > prefetch queue
  VampireIndex/          GRDB store: index, faces, sessions, journal
App/
  Model/                 CullItem + image providers (Photos library / camera cache)
  Camera/                PTP/IP transport, Sony client, session cache, finder, import
  Indexing/              PhotoKit head reads, Vision pass, indexer
  UI/                    sessions, grid, pager (incl. wide layout), HUD, faces
  Apply/                 the only code that mutates the Photos library
fixtures/                real RAW/JPEG files + exiftool ground truth
tools/                   fake camera, PTP/IP probe
store/                   App Store copy + screenshot compositor
```

[SPEC.md](SPEC.md) has the architecture; [CLAUDE.md](CLAUDE.md) the hard
constraints (no incremental deletes, never decode a full RAW on the scroll
path, metadata from file heads only, never delete on the camera, …).

## Simulator notes

- Vision doesn't run in the simulator (no Neural Engine): no faces or scores
  there; everything else works. DEBUG builds import any RAW dropped into the
  app's `Documents/` (`simctl addmedia` rejects RAW).
- The simulator's network isn't typed Wi-Fi, so simulator builds drop the
  Wi-Fi interface pin for camera connections.
- iPhone Duo: Xcode 27.1's Duo simulator boots folded; unfold it in Device
  Hub. Capture each screen with `simctl io <udid> screenshot --display=1`
  (outer, 1398×2034) or `--display=3` (inner, 2007×2853).

## Releasing (maintainers)

Archive with an App Store Connect API key from your environment — never
commit `.p8` files (`*.p8` is gitignored):

```sh
xcodebuild -scheme Vampire -destination 'generic/platform=iOS' archive \
  -archivePath build/Vampire.xcarchive -allowProvisioningUpdates \
  -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" \
  -authenticationKeyIssuerID "$ASC_ISSUER_ID"
xcodebuild -exportArchive -archivePath build/Vampire.xcarchive \
  -exportOptionsPlist ExportOptions.plist -exportPath build/export
xcrun altool --upload-app --type ios --file build/export/Vampire.ipa \
  --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER_ID"
```

## License

[MIT](LICENSE). The photos in `fixtures/` are the author's own and are
included for testing this project.
