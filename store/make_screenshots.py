#!/usr/bin/env python3
"""Composites raw app captures onto the twilight marketing background
(Didot headline + subtitle), at App Store sizes.

    python3 store/make_screenshots.py <capture.png> <out.png> "Headline line 1|line 2" "Subtitle"
        [--size=1320x2868] [--fit]

Captures come from the simulator (`xcrun simctl io <udid> screenshot`), with
the status bar pinned to 9:41 (`simctl status_bar … override`). For camera
sessions without a camera, serve fixtures with tools/fake_a7rv.py.
"""
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

# Sampled from the v1.0 set: dusk navy → violet → blue-teal.
STOPS = [(0.0, (18, 20, 42)), (0.14, (26, 26, 54)), (0.28, (35, 33, 67)),
         (0.49, (48, 43, 86)), (0.70, (49, 51, 93)), (1.0, (39, 56, 89))]
DIDOT = "/System/Library/Fonts/Supplemental/Didot.ttc"
SANS = "/System/Library/Fonts/SFNS.ttf"

def gradient(w, h):
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / (h - 1)
        for (t0, c0), (t1, c1) in zip(STOPS, STOPS[1:]):
            if t0 <= t <= t1:
                f = (t - t0) / (t1 - t0)
                color = tuple(round(a + (b - a) * f) for a, b in zip(c0, c1))
                break
        for x in range(w):
            px[x, y] = color
    return img

def compose(capture, out, headline, subtitle, size=(1320, 2868), fit=False):
    W, H = size
    s = W / 1320  # layout was designed at 1320 wide
    canvas = gradient(W, H)
    draw = ImageDraw.Draw(canvas)

    title_font = ImageFont.truetype(DIDOT, round(132 * s))
    sub_font = ImageFont.truetype(SANS, round(46 * s))
    y = round(215 * s)
    for line in headline.split("|"):
        box = draw.textbbox((0, 0), line, font=title_font)
        draw.text(((W - (box[2] - box[0])) / 2 - box[0], y), line, font=title_font, fill=(246, 243, 250))
        y += round(132 * s)
    box = draw.textbbox((0, 0), subtitle, font=sub_font)
    draw.text(((W - (box[2] - box[0])) / 2 - box[0], y + round(30 * s)), subtitle,
              font=sub_font, fill=(196, 190, 220))

    # The capture as a rounded "device" panel, bleeding off the bottom edge.
    shot = Image.open(capture).convert("RGB")
    top = round(860 * s)
    panel_w = round(1028 * s)
    if fit:  # whole capture visible (e.g. a bottom status bar matters)
        panel_w = round((H - top - 70 * s) * shot.width / shot.height)
    panel_h = round(shot.height * panel_w / shot.width)
    shot = shot.resize((panel_w, panel_h), Image.LANCZOS)
    left = (W - panel_w) // 2
    radius = round(72 * s)
    mask = Image.new("L", (panel_w, panel_h), 0)
    bottom_pad = 0 if fit else radius  # fitted panels round all corners
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, panel_w, panel_h + bottom_pad), radius=radius, fill=255)
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle((left, top + 10, left + panel_w, (top + panel_h) if fit else H + radius),
                                             radius=radius, fill=150)
    canvas = Image.composite(Image.new("RGB", (W, H), (8, 8, 20)), canvas, shadow.filter(ImageFilter.GaussianBlur(28 * s)))
    canvas.paste(shot, (left, top), mask)
    canvas.save(out, optimize=True)

if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    size = (1320, 2868)
    for a in sys.argv[1:]:
        if a.startswith("--size"):
            w, h = a.split("=", 1)[1].split("x")
            size = (int(w), int(h))
    compose(args[0], args[1], args[2], args[3], size, fit="--fit" in sys.argv)
