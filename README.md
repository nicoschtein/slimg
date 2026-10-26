<div align="center">

<img src="brand/logomark.svg" alt="Slimg" width="96" height="96">

# Slimg

### Slim your images. Lose nothing.

Lossless image optimizer for macOS. Slimg strips metadata and re-packs
JPEG, PNG, GIF and HEIC files so they get smaller **without ever changing a single
pixel** — the output decodes byte-for-byte identically to the input, and is
never larger than what you started with.

[![CI](https://github.com/nicoschtein/slimg/actions/workflows/ci.yml/badge.svg)](https://github.com/nicoschtein/slimg/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/nicoschtein/slimg?sort=semver)](https://github.com/nicoschtein/slimg/releases/latest)
[![License: MIT](https://img.shields.io/badge/license-MIT-14B8A6.svg)](LICENSE)
[![Platform: macOS 13+](https://img.shields.io/badge/macOS-13%2B-0D9488.svg)](https://github.com/nicoschtein/slimg/releases/latest)
[![100% on-device](https://img.shields.io/badge/100%25-on--device-06B6D4.svg)](#privacy--guarantees)

[**Website**](https://slimg.app) · [**Download**](https://github.com/nicoschtein/slimg/releases/latest) · [**Roadmap**](ROADMAP.md) · [**Contributing**](CONTRIBUTING.md) · [**Security**](SECURITY.md)

</div>

---

## Contents

- [Why Slimg](#why-slimg)
- [Lossless vs lossy](#lossless-vs-lossy)
- [Screenshots](#screenshots)
- [Install](#install)
  - [Download the app](#1-download-the-app-dmg)
  - [Download the CLI](#2-download-the-cli)
  - [Build from source](#3-build-from-source)
- [Usage](#usage)
  - [The app](#the-app)
  - [The CLI](#the-cli)
- [How it works](#how-it-works)
- [Privacy & guarantees](#privacy--guarantees)
- [Project layout](#project-layout)
- [Contributing](#contributing)
- [Security](#security)
- [License](#license)

---

## Why Slimg

Most images carry weight you never see: EXIF camera data, GPS coordinates,
Adobe XMP, IPTC blocks, editor comments, timestamps, and PNG image data that
was deflated at a lazy compression level. None of it affects how the picture
looks. All of it costs bytes — and, in the case of EXIF/GPS, can leak where and
when a photo was taken.

Slimg removes that weight and re-packs what's left, while leaving the actual
image untouched. It does one thing carefully:

- **Truly lossless.** Pixels are never touched. Re-decoding the output yields
  byte-identical pixels, and the file is never larger than the input.
- **Private by design.** 100% on-device. No uploads, no servers, no accounts,
  no telemetry. Your images never leave your Mac.
- **Native & local.** A Swift macOS app and CLI with compiled-in JPEG and Zopfli
  libraries. No Electron, separately installed tools, or background daemons.
- **Transparent.** An advanced report shows exactly what was removed (EXIF,
  XMP, IPTC, comments, timestamps, re-deflated PNG data) and how many bytes
  each item saved. Open source, auditable.

## Lossless vs lossy

Slimg is **not** a TinyPNG-style compressor, and that's the whole point.

| | Slimg (lossless) | "Visually lossless" lossy tools |
|---|---|---|
| Pixels | Never changed; output decodes byte-identically | Re-encoded / quantized; pixels change |
| Savings | Modest, from metadata + re-deflate | Large, by throwing away image detail |
| Reversible | Yes — re-decode gives the original image | No — discarded detail is gone |
| Color | ICC profiles kept by default | Often altered |
| Best for | Archives, assets you must not degrade, repeat-safe pipelines | Web images where some quality loss is acceptable |

If you need aggressive size reduction and can tolerate quality loss, a lossy
tool (TinyPNG, ImageOptim's lossy modes, `pngquant`, `mozjpeg` re-encode) will
beat Slimg on raw kilobytes. If you must not degrade the image — and you'd
rather not trust the "visually" in "visually lossless" — Slimg is for you. You
can run Slimg over a folder repeatedly and it will only ever shrink or no-op;
it never compounds loss because there is no loss.

## Screenshots

> **TODO (assets):** app screenshots and the animated demo live on the
> [website](https://slimg.app) and under `docs/` once captured. Placeholders are
> noted here so the layout is ready:
>
> - `docs/screenshot-drop.png` — drag-and-drop empty state
> - `docs/screenshot-results.png` — file list with savings and the advanced report
>
> Until those are added, see [slimg.app](https://slimg.app) for the live demo.

## Install

Slimg ships as two products from one Swift package: the **Slimg** app (a SwiftUI
GUI) and the **`slimg`** command-line tool. Requires **macOS 13 or newer**.

### 1. Download the app (DMG)

1. Grab `Slimg.dmg` from the
   [latest release](https://github.com/nicoschtein/slimg/releases/latest).
2. Open the DMG and drag **Slimg** into **Applications**.

> **First launch (open source, ad-hoc signed builds):** Slimg is open source.
> If a build is not yet Developer-ID notarized, macOS Gatekeeper may refuse to
> open it on the first try. **Right-click (or Control-click) the app → Open →
> Open** to launch it the first time. You only need to do this once. Notarized,
> Developer-ID-signed builds are on the [roadmap](ROADMAP.md).

### 2. Download the CLI

1. Download `slimg-cli-macos.tar.gz` from the
   [latest release](https://github.com/nicoschtein/slimg/releases/latest).
2. Unpack and place the binary on your `PATH`:

   ```sh
   tar -xzf slimg-cli-macos.tar.gz
   sudo mv slimg /usr/local/bin/
   slimg --help
   ```

   If macOS quarantines the downloaded binary, clear the flag once with
   `xattr -d com.apple.quarantine /usr/local/bin/slimg`.

> **Homebrew (planned):** a Homebrew cask/tap is on the [roadmap](ROADMAP.md).
> There is no tap yet — use the tarball above for now.

### 3. Build from source

You'll need Xcode 15 or newer (Swift 5.9+ toolchain) on macOS 13+.

```sh
git clone https://github.com/nicoschtein/slimg.git
cd slimg

# Build and test the library + CLI
swift build -c release
swift test

# Build the double-clickable Slimg.app bundle
./Scripts/build-app.sh                 # release build
./Scripts/build-app.sh release --universal   # arm64 + x86_64
```

The compiled CLI lands in `.build/release/slimg`, and `build-app.sh` produces
`Slimg.app` in the repo root. Slimg links system `zlib` and builds pinned,
vendored libjpeg-turbo and Google Zopfli sources into the app and CLI. No
additional tools or package downloads are needed to build or use Slimg. See
[third-party notices](THIRD_PARTY_NOTICES.md) for versions and licenses.

## Usage

### The app

1. Open **Slimg**.
2. **Drag images (or a folder) onto the window**, or click **Add Images**
   (`⌘O`). Folders are scanned recursively for `.jpg`, `.jpeg`, `.png`, `.gif`,
   `.heic` and `.heif` files.
3. Each file is optimized as it's added. The footer shows total bytes saved;
   each row shows its savings and a button to open the **advanced report**
   listing exactly what was removed.

**Keep originals** is on by default: Slimg writes the optimized image under its
original name and backs the original up as `name.bak.ext`. Turn it off (in the
header toggle or in **Settings**) to optimize in place. Settings also expose
metadata stripping, ICC color-profile stripping (off by default), and lossless
PNG re-compression.

**Additional lossless optimization** settings are all **off by default**:

| Setting | What it tries |
|---|---|
| Deep PNG compression | Reversible scanline filters and multiple zlib strategies. |
| Maximum PNG compression (Zopfli) | A slower search for a smaller DEFLATE stream. |
| Reduce PNG color storage exactly | Exact palettes, opaque-alpha removal, and exactly representable sample/index depths. No quantization. |
| Optimize PNG chunks and profiles | Consolidate image chunks and recompress retained ICC profiles without changing their contents. |
| Optimize JPEG Huffman coding | Encode existing JPEG coefficients with optimized entropy tables. |
| Try progressive JPEG encoding | Try a progressive scan arrangement of the existing coefficients. |
| Recompress GIF image data | Recompress unchanged frame indices; preserve palettes, frame layout, transparency, disposal, timing, and looping. |

Only smaller results are retained. Advanced methods have resource limits and
conservatively skip unsupported layouts. PNG representation changes preserve
native sample values, including RGB hidden under full transparency, and skip
animation, interlacing, HDR, and metadata needing unsupported rewrites. Zopfli
is limited to 1 MiB of filtered image data. These settings can take considerably
longer; savings depend on how the original file was encoded.

### The CLI

`slimg` takes one or more file paths and optimizes them in place. Pass
`--report` (or `-v`) to see the breakdown:

```console
$ slimg --report photo.jpg
  ok    photo.jpg [JPEG] 2.4 MB -> 2.1 MB  −12.6%
        removed  EXIF metadata (APP1)  (288.0 KB)
        removed  XMP metadata (APP1)  (12.4 KB)
        removed  Application data (APP13)  (3.1 KB)
```

Optimize several files and Slimg prints a total:

```console
$ slimg *.png
  ok    banner.png [PNG] 540.2 KB -> 488.0 KB  −9.7%
  ----  logo.png [PNG] already optimal (4.1 KB)
  ok    hero.png [PNG] 1.2 MB -> 1.1 MB  −8.3%

Total: 1.7 MB -> 1.6 MB  saved 122.0 KB (6.9%)
```

Preview without writing anything:

```console
$ slimg --dry-run --report screenshot.png
  would screenshot.png [PNG] 820.0 KB -> 712.0 KB  −13.2%
        shrank   Recompressed image data (IDAT)  (96.0 KB)
        removed  Text: Software (tEXt)  (12.0 KB)
```

#### Flags

| Flag | Effect |
|---|---|
| `--dry-run` | Report savings without writing any files. |
| `--backup`, `--copy` | Keep the original as `name.bak.ext`; write the optimized image under its original name. (Off by default — the CLI optimizes in place unless you ask for a backup.) |
| `--report`, `-v` | Print an advanced breakdown of what was removed. |
| `--keep-metadata` | Do **not** strip EXIF / XMP / IPTC / comments. |
| `--strip-color` | Also strip ICC color profiles (may shift colors). HEIC profiles are always kept. |
| `--no-recompress` | Skip lossless PNG re-compression. |
| `--deep-png` | Try additional reversible PNG filters and compression strategies. |
| `--zopfli-png` | Try maximum PNG compression (much slower). |
| `--reduce-png` | Try exact PNG color/sample storage reductions. |
| `--optimize-png` | Consolidate PNG image chunks and recompress retained profiles. |
| `--optimize-jpeg` | Optimize JPEG Huffman coding without changing coefficients. |
| `--progressive-jpeg` | Try progressive JPEG coding without changing coefficients. |
| `--recompress-gif` | Recompress GIF frame indices without changing the animation. |
| `-h`, `--help` | Show usage. |

Run with no arguments (or `--help`) to print usage. Unsupported files are
skipped; files that are already optimal are left untouched. Pixels are never
altered, and output is never larger than the input. Supported formats: JPEG,
PNG, GIF, HEIC/HEIF (HEVC images).

The seven additional methods require their explicit flags. `--no-recompress`
disables the standard PNG pass; an explicit advanced flag still enables its
own method. Metadata controls apply independently of compression settings.

> **Note:** the CLI operates on the paths you give it — it does not recurse into
> directories. To process a tree, expand it with your shell (e.g.
> `slimg **/*.png`). The app does recurse into dropped folders.

## How it works

Slimg parses JPEG, PNG and GIF containers itself, and uses macOS ImageIO's
lossless copy operation for HEIC. It rewrites only the parts that don't affect
rendered pixels. On any structural surprise an optimizer bails out and the
original bytes are kept verbatim, so a file Slimg doesn't fully understand is
never corrupted. A final safety net guarantees the output is never larger than
the input — if an optimizer can't beat the original, the original is returned
unchanged.

- **JPEG** — drops metadata marker segments: APP1 (EXIF/XMP), APP3–APP13,
  APP15, and `COM` comments. APP0 (JFIF) and APP14 (Adobe) are kept because
  they're needed to interpret the image; an APP2 ICC profile is kept by default.
  The entropy-coded scan data (everything from `SOS` onward) is copied
  byte-for-byte by default. Optional Huffman/progressive optimization reads and
  writes the existing quantized coefficients through libjpeg-turbo without
  decoding/re-encoding pixels or changing quantization/subsampling. It retains
  only smaller candidates and preserves the remaining marker metadata.
- **PNG** — drops metadata chunks (`tEXt`, `zTXt`, `iTXt`, `tIME`, `eXIf`) and,
  only if you ask, `iCCP`. It also re-inflates and **re-deflates the `IDAT`
  image data at zlib level 9**: the decompressed filtered scanlines are
  identical, so decoded pixels are unchanged — only the compression is tighter.
  All rendering-relevant chunks (`IHDR`, `PLTE`, `tRNS`, `gAMA`, `cHRM`, `sRGB`,
  `sBIT`, `bKGD`, `pHYs`, …) are preserved. Optional deep filtering, exact
  representation reductions, chunk/profile optimization and Zopfli compression
  extend this path without changing samples or color interpretation.
- **GIF** — drops Comment Extensions and non-essential Application Extensions
  (e.g. XMP). The `NETSCAPE` looping extension, all graphic-control extensions,
  color tables and the LZW image data are preserved, so frames and animation
  timing are untouched. Optional LZW recompression rewrites the compression of
  exactly the same indices, retaining descriptors, palettes and animation
  controls verbatim; frame cropping and delta rewriting are not performed.
- **HEIC / HEIF** — removes known descriptive EXIF, GPS, XMP and IPTC metadata
  using `CGImageDestinationCopyImageSource`, which copies compressed image data
  without re-encoding it. Orientation, color profiles and unfamiliar metadata
  namespaces (which can carry HDR rendering information) are preserved. The
  report gives combined metadata and container savings. HEIC color profiles
  are always retained, including with `--strip-color`. Files that ImageIO cannot
  copy losslessly, and multi-image collections, are left untouched. This supports
  HEVC images in `.heic` / `.heif` files, not AVIF or other HEIF codecs.

Color profiles (ICC) are **kept by default** in every format — stripping them
can shift how colors appear, so it's strictly opt-in (`--strip-color`, or the
Settings toggle in the app).

## Privacy & guarantees

- **On-device.** Everything happens locally. No network access, no uploads, no
  accounts, no telemetry.
- **Lossless.** Pixels are never modified. The optimized image decodes
  byte-for-byte identically to the original — this is enforced by the test suite
  (see [`Tests/SlimgCoreTests`](Tests/SlimgCoreTests)).
- **Never larger.** Output is never bigger than the input; if Slimg can't shrink
  a file, it leaves it exactly as-is.
- **Originals are safe.** The app keeps a `name.bak.ext` backup by default, and
  never overwrites an existing backup. The CLI optimizes in place; pass
  `--backup` to keep a copy.

## Project layout

```
Sources/
  SlimgCore/    Lossless optimizers (JPEG, PNG, GIF, HEIC) + zlib wrapper — the engine
  CZlib/        Tiny C shim that links the system zlib
  CJPEG/        Pinned libjpeg-turbo sources and a coefficient-copy C bridge
  CZopfli/      Pinned Google Zopfli compression sources and C bridge
  slimg/        Command-line tool (main.swift)
  SlimgApp/     SwiftUI macOS app (Slimg.app)
Tests/
  SlimgCoreTests/   Pixel-identity & "never grows" tests — the golden rules
Scripts/
  build-app.sh      Assembles Slimg.app from the SwiftPM build product
Resources/          Info.plist, app icon
brand/              Brand guidelines, logomark, wordmark, icon master
site/               Landing page sources (slimg.app)
```

## Contributing

Contributions are welcome — bug reports, formats, UX, docs. The one rule that
never bends: **changes must stay lossless** (never alter pixels, never grow
files). PRs that break the pixel-identity tests will not be merged. See
[CONTRIBUTING.md](CONTRIBUTING.md) for setup, project structure, and how to add
a format optimizer.

## Security

Found a vulnerability or a way to make Slimg corrupt or grow a file? Please
report it privately — see [SECURITY.md](SECURITY.md). Do not open a public
issue for security reports.

## License

[MIT](LICENSE) © 2026 Nicolas Schteinschraber and Slimg contributors.
