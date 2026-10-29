# App Store listing (v1.1)

App: "Vampire - The Photo Cullin App" (com.chriskonstad.vampire) — the name is
a Twilight pun: **cull**ing + the **Cullen** family. Theme is elegant/immortal
vampire (dusk, forever, refined taste), NOT horror/gore.

**Subtitle:** Cull like a Cullen

**Promotional text (1.1):**
New: cull straight off your Sony camera over Wi-Fi and bring home only the
keepers. Free forever, no subscription — and now open source.

**Marketing URL:** https://github.com/chriskonstad/vampire ·
**Support URL:** https://github.com/chriskonstad/vampire/issues ·
**Privacy:** https://privacy.konstad.me

**Description (1.1)** adds: a "Cull right off your camera" section (tested on
α7R V; likely-compatible list; one-line camera setup) and "Free forever. Open
source." (MIT, GitHub link). Always say: free, no subscription, no ads, no IAP.

**Description:** see the App Store; opens "Some frames are worth an eternity…",
closes "Cull like a Cullen. Keep only the immortals."

**Screenshots** (store/mk-*.png, 1320×2868, Didot serif on a twilight gradient):
0a. "Cull right off your camera." — camera-session pager (fake A7RV + Mac Vision)
0b. "Only keepers come home." — camera grid + link status (`--fit`)
1. "Know it nailed focus." — AF hero + HUD
2. "Every signal, at a glance." — grid HUD
3. "Keep only the immortals. / Rip through a shoot. Cull like a Cullen." — pager

Regenerate screenshots: store/make_screenshots.py (composites app captures onto
the twilight background). Captures come from the simulator; camera sessions use
tools/fake_a7rv.py, and since Vision can't run in the simulator, run the app's
VisionAnalyzer on the Mac over the previews and write the results into the
simulator's index so faces/scores are real, not drawn in.

**iPhone Duo:** App Store Connect has an iPhone Duo slot (inner 2007×2853,
outer 1398×2034); filling it shows an "optimized for iPhone Duo" badge. The
app's wide layout targets it, but native Duo rendering needs the iOS 27.1 SDK
(Xcode 27.1) — with 27.0 the Duo letterboxes the app. Don't claim Duo support
until a 27.1-SDK build is verified.

## Still off-theme (needs a NEW binary build to fix)
- App icon: currently the horror fanged-aperture with a blood drop. A
  Twilight-elegant redesign needs a rebuild + re-upload.
- In-app auth tagline (VampireApp.swift): "Keep the blood, spit out the rest"
  is horror-voiced; the Cullen voice would be "Keep only the immortals."
