# ARW fixtures

Real A7RV ARW files for TDD'ing the MakerNotes parser. Per CLAUDE.md, the
parser never relies on a layout assumption that hasn't been validated against
a file in this directory.

**Target coverage** (one file each):
- single shot
- ~10fps burst (a few consecutive frames)
- eye-AF on a person
- manual focus
- APS-C crop mode (coordinate framing changes!)

## Adding a fixture

1. Drop `<name>.ARW` here.
2. Capture ground truth: `exiftool -a -G1 -v3 <name>.ARW > <name>.exiftool.txt`
   (install exiftool via `brew install exiftool`).
3. Record the expected values in `<name>.expected.json`:

   ```json
   {
     "model": "ILCE-7RM5",
     "focusLocation": [9504, 6336, 4752, 3168]
   }
   ```

   `focusLocation` is Sony tag 0x2027 as exiftool reports it:
   `[imageWidth, imageHeight, focusX, focusY]`. Omit it for manual-focus
   frames where the tag is absent or zeroed.

4. `cd VampireCore && swift test --filter RealFixtureTests` — the harness
   auto-discovers every `*.ARW` here, parses only the first 1MB (same as the
   app), and checks it against the JSON. Without a JSON it prints what it
   parsed so you can diff against the exiftool dump before committing it as
   ground truth.

With no ARW files present the fixture test skips; synthetic structural
coverage lives in `ARWHeadParserTests`.
