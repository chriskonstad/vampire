#!/usr/bin/env python3
"""Builds a fake A7RV card for tools/fake_a7rv.py from the repo fixtures:
a 4-frame burst, a 3-frame portrait burst, and two separate frames.

    python3 tools/make_fake_card.py /tmp/fakecard [--extra]

`--extra` adds two more shots "taken later" — rerun with/without it between
connects to test new shots joining and removed shots dropping out.
Needs exiftool and sips (macOS).
"""
import json, os, subprocess, sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FIX = os.path.join(REPO, "fixtures")

def run(*args, out=None):
    if out:
        with open(out, "wb") as f:
            subprocess.run(args, check=True, stdout=f)
    else:
        subprocess.run(args, check=True, stdout=subprocess.DEVNULL)

def main():
    card = sys.argv[1]
    os.makedirs(card, exist_ok=True)
    # Upright screennails (the app maps AF through the head's orientation).
    run("exiftool", "-b", "-PreviewImage", f"{FIX}/DSC04319.ARW", out=f"{card}/runners_sn.jpg")
    run("exiftool", "-b", "-PreviewImage", f"{FIX}/DSCF2030.raf", out=f"{card}/sunset_pv.jpg")
    run("sips", "-Z", "1616", f"{card}/sunset_pv.jpg", "--out", f"{card}/sunset_sn.jpg")
    run("sips", "-r", "270", "-Z", "1616", f"{FIX}/DSCF2763.jpg", "--out", f"{card}/portrait_sn.jpg")
    for name in ("runners", "sunset", "portrait"):
        run("sips", "-Z", "160", f"{card}/{name}_sn.jpg", "--out", f"{card}/{name}_th.jpg")
    run("exiftool", "-overwrite_original", "-Orientation=", *[f"{card}/{n}" for n in os.listdir(card) if n.endswith(".jpg")])

    base = 1_793_200_000_000  # ms
    runners = dict(source=f"{FIX}/DSC04319.ARW", screennail="runners_sn.jpg", thumb="runners_th.jpg",
                   format="B101", width=9504, height=6336)
    portrait = dict(source=f"{FIX}/DSCF2763.jpg", screennail="portrait_sn.jpg", thumb="portrait_th.jpg",
                    format="3801", width=7728, height=5152)
    sunset = dict(source=f"{FIX}/DSCF2030.raf", screennail="sunset_sn.jpg", thumb="sunset_th.jpg",
                  format="B101", width=7728, height=5152)
    shots = []
    n = 5001
    for i in range(4):  # 10fps-ish burst
        shots.append(dict(runners, name=f"DSC0{n}.ARW", created_ms=base + i * 120)); n += 1
    for i in range(3):
        shots.append(dict(portrait, name=f"DSC0{n}.JPG", created_ms=base + 60_000 + i * 400)); n += 1
    for i in range(2):
        shots.append(dict(sunset, name=f"DSC0{n}.ARW", created_ms=base + 600_000 + i * 30_000)); n += 1
    if "--extra" in sys.argv:
        for i in range(2):
            shots.append(dict(runners, name=f"DSC0{n}.ARW", created_ms=base + 86_400_000 + i * 5_000)); n += 1
    with open(f"{card}/card.json", "w") as f:
        json.dump(shots, f, indent=1)
    print(f"{len(shots)} shots in {card}/card.json")

if __name__ == "__main__":
    main()
