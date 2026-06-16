# Slimg — Brand Guidelines

> Single source of truth for the Slimg brand. The landing site, macOS app UI,
> icon set, README, and all marketing assets must derive their colors, type,
> logo, and voice from this file. If something here conflicts with an older
> asset, this file wins.

---

## 1. The name

**Slimg** — a portmanteau of **slim** + **img** (image).

- Always written **Slimg** (cap S) in prose and the macOS app.
- The lowercase **`slimg`** wordmark is used for the logo lockup and the CLI binary.
- Pronounced "slim-image" / "slimj". Domain: **slimg.app**. Repo: **github.com/nicoschtein/slimg**.

## 2. What Slimg is (positioning)

Slimg is a **lossless image optimizer for macOS**. It strips metadata and
re-packs JPEG/PNG/GIF files so they get smaller **without ever changing a
single pixel**. It is the opposite of "visually lossless" lossy compressors
(TinyPNG et al.) — Slimg's output decodes byte-for-byte identically to the input.

### Positioning pillars (use these as feature themes everywhere)

1. **Truly lossless** — pixels are never touched. Re-decoding the output yields
   byte-identical pixels. Output is never larger than the input.
2. **Private by design** — 100% on-device. No uploads, no servers, no accounts,
   no telemetry. Your images never leave your Mac.
3. **Native & fast** — a small, pure-Swift macOS app + CLI. No Electron, no
   bundled third-party binaries, no background daemons.
4. **Transparent** — an "advanced report" shows exactly what was removed
   (EXIF, XMP, IPTC, comments, timestamps, re-deflated PNG data) and how many
   bytes each item saved. Open source, auditable.

### One-liners

- **Primary tagline:** *Slim your images. Lose nothing.*
- Support line: *Lossless image optimization for macOS — strips metadata and
  extra weight, never a pixel.*
- Short (icon/social): *Lossless image slimming for Mac.*

## 3. Voice & tone

Precise, calm, confident, a little nerdy-honest. We make exact claims and we
can back them up. Avoid hype words ("magical", "revolutionary"). Prefer
concrete numbers and mechanisms ("re-deflates IDAT at zlib level 9", "drops
APP1 EXIF segments"). Respect the reader's intelligence and their privacy.

## 4. Color

The palette is a teal→cyan brand spectrum over deep-navy ink, with warm slate
neutrals. Teal reads "optimized / efficient / trustworthy" without being the
generic dev-tool indigo.

### Brand core

| Token        | Hex        | Use                                              |
|--------------|------------|--------------------------------------------------|
| Teal 400     | `#2DD4BF`  | Gradient **start**, glow, light accent on dark   |
| Teal 500     | `#14B8A6`  | **Primary** — app tint, buttons, links (solid)   |
| Teal 600     | `#0D9488`  | Pressed / hover-dark / depth                     |
| Cyan 500     | `#06B6D4`  | Gradient **end**, secondary accent               |
| Mint 300     | `#5EEAD4`  | Highlights, focus rings, subtle glows            |

**The Slimg Gradient** (signature — icon, hero, primary CTA):
`linear-gradient(135deg, #2DD4BF 0%, #06B6D4 100%)`
SwiftUI: `LinearGradient(colors: [#2DD4BF, #06B6D4], startPoint: .topLeading, endPoint: .bottomTrailing)`

### Dark neutrals (hero / dark UI)

| Token     | Hex        | Use                          |
|-----------|------------|------------------------------|
| Ink 950   | `#0A0F1A`  | Hero / darkest background    |
| Ink 900   | `#0E1626`  | Dark surface                 |
| Ink 800   | `#172234`  | Elevated card on dark        |
| Slate 200 | `#E2E8F0`  | Primary text on dark         |
| Slate 400 | `#94A3B8`  | Secondary text on dark       |

### Light neutrals (light site sections / app light mode)

| Token     | Hex        | Use                          |
|-----------|------------|------------------------------|
| Paper     | `#FFFFFF`  | Cards / app window base      |
| Mist      | `#F8FAFC`  | Page background              |
| Cloud     | `#F1F5F9`  | Subtle surface fill          |
| Line      | `#E2E8F0`  | Borders / dividers           |
| Graphite  | `#0F172A`  | Primary text on light        |
| Slate 500 | `#64748B`  | Secondary text on light      |

### Semantic

| Token    | Hex        | Use                                  |
|----------|------------|--------------------------------------|
| Success  | `#22C55E`  | Savings %, "done", positive deltas   |
| Warning  | `#F59E0B`  | "skipped / already optimal"          |
| Danger   | `#EF4444`  | Errors / failures                    |

Always support light **and** dark appearance. On the web, default to a dark
hero with light content sections. In the macOS app, follow the system
appearance and use the teal tint as accent in both.

## 5. Typography

- **Headings / display:** `Inter` on the web (700/600, tracking `-0.02em` at
  large sizes); **SF Pro / system** in the app (`.system(..., design: .rounded)`
  is acceptable for numerics/badges).
- **Body / UI:** `Inter` (web) / system (app), 400–500.
- **Monospace** (CLI snippets, byte counts, code): `"SF Mono", ui-monospace,
  "JetBrains Mono", Menlo, monospace`. Use monospaced digits for size/percent
  figures (`.monospacedDigit()` in SwiftUI, `font-variant-numeric: tabular-nums`
  on the web).

Web font loading: self-host or use a `font-display: swap` web font for Inter,
with a robust system fallback: `Inter, -apple-system, BlinkMacSystemFont,
"Segoe UI", Roboto, sans-serif`.

## 6. Logo

### The mark — "the squeeze"

Two chevrons pressing **inward** toward a central rounded vertical bar:
`>` `|` `<`. It reads instantly as *compress / slim / minimize*, and the
central bar is "the image" being slimmed. Geometry (canonical, on a `0 0 100
100` grid, centered):

- **Central bar:** vertical rounded rect, width ~8, height ~48, centered at
  x=50, y 26→74, corner radius ~4. This is the slimmed image.
- **Left chevron** (points right, `>`): polyline `(26,28) → (40,50) → (26,72)`,
  round caps & joins, stroke width ~9.
- **Right chevron** (points left, `<`): polyline `(74,28) → (60,50) → (74,72)`.

Master files (do not redraw by hand — reuse these):

- `brand/icon-master.svg` — 1024×1024 app icon (gradient squircle + white mark).
- `brand/logomark.svg` — the mark alone, teal gradient, transparent bg.
- `brand/wordmark.svg` — horizontal lockup: mark + `slimg`.

### Wordmark

`slimg` set lowercase in Inter/SF **700**, tracking `-0.03em`, in Graphite
(light) or White (dark). The mark sits to the **left** with clearspace equal to
the cap-height. Optionally the mark uses the Slimg Gradient while the word stays
neutral — never gradient-fill the text and the mark at once.

### Clearspace & sizing

- Minimum clearspace around the lockup = height of the central bar of the mark.
- Mark minimum size: 16px (favicon) — at ≤16px use the mark only, no word.

### App icon

- Canonical shape is the **macOS continuous-corner squircle** (superellipse),
  not a plain rounded rect. The icon generator must bake the squircle (full
  bleed, no transparent margin — macOS does **not** mask `.icns`).
- Background = Slimg Gradient (135°). Mark = white (`#FFFFFF`) with a soft inner
  highlight; optional subtle top-light. Keep it clean and legible at 16px.

### Don'ts

- Don't recolor the mark outside the brand teals (white-on-gradient or
  teal-on-neutral only).
- Don't add drop shadows to the wordmark text, rotate the mark, or stretch it.
- Don't place the gradient mark on a busy photo without a solid chip behind it.

## 7. Asset & integration contracts (so parallel work fits together)

These exact names/paths are a contract between the app, icon, CI, site and docs:

- **App icon file:** `Resources/AppIcon.icns`; Info.plist `CFBundleIconFile` =
  `AppIcon`. Iconset sizes: 16, 32, 128, 256, 512 px each at @1x and @2x
  (i.e. up to 1024), built with `iconutil`.
- **Web icon exports** (produced by the icon generator into `brand/web/`):
  `favicon.svg`, `favicon-32.png`, `favicon-180.png` (apple-touch),
  `icon-512.png`, `og-image.png` (1200×630 social card). The site references
  copies of these under `site/assets/`.
- **Bundle id:** `com.aguara.slimg`. **Min macOS:** 13.0.
- **CI workflow filenames:** `.github/workflows/ci.yml` (build+test on push/PR),
  `.github/workflows/release.yml` (tag → signed app + CLI + GitHub Release),
  `.github/workflows/pages.yml` (deploy `site/` to GitHub Pages).
- **Release asset names** (what the site's download button links to):
  - `Slimg.dmg` — universal (arm64 + x86_64) drag-to-install app.
  - `slimg-cli-macos.tar.gz` — universal CLI binary + README + LICENSE.
  - Download landing URL: `https://github.com/nicoschtein/slimg/releases/latest`.
- **Custom domain:** `slimg.app` (GitHub Pages `CNAME` = `slimg.app`).
- **Versioning:** semver; release tags are `vX.Y.Z`; the app's
  `CFBundleShortVersionString` is injected from the tag in CI.

## 8. Quick reference — copy/paste tokens

CSS custom properties:

```css
:root {
  --teal-400:#2DD4BF; --teal-500:#14B8A6; --teal-600:#0D9488;
  --cyan-500:#06B6D4; --mint-300:#5EEAD4;
  --ink-950:#0A0F1A; --ink-900:#0E1626; --ink-800:#172234;
  --slate-200:#E2E8F0; --slate-400:#94A3B8; --slate-500:#64748B;
  --paper:#FFFFFF; --mist:#F8FAFC; --cloud:#F1F5F9; --line:#E2E8F0;
  --graphite:#0F172A; --success:#22C55E; --warning:#F59E0B; --danger:#EF4444;
  --slimg-gradient: linear-gradient(135deg,#2DD4BF 0%,#06B6D4 100%);
}
```

Swift (sRGB):

```swift
enum Brand {
  static let teal400 = Color(red: 0.176, green: 0.831, blue: 0.749) // #2DD4BF
  static let teal500 = Color(red: 0.078, green: 0.722, blue: 0.651) // #14B8A6
  static let teal600 = Color(red: 0.051, green: 0.580, blue: 0.533) // #0D9488
  static let cyan500 = Color(red: 0.024, green: 0.714, blue: 0.831) // #06B6D4
  static let mint300 = Color(red: 0.369, green: 0.918, blue: 0.831) // #5EEAD4
  static let success = Color(red: 0.133, green: 0.773, blue: 0.369) // #22C55E
}
```
