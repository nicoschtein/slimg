# Slimg Roadmap

This is where Slimg is going. It follows [Semantic Versioning](https://semver.org):
release tags are `vX.Y.Z`. The roadmap is intentionally modest — Slimg is a
small, focused macOS utility, and every item here is measured against the
founding principle: **truly lossless, never a pixel changed, never a larger
file.** Anything that would compromise that is a non-goal, not a future feature.

**Status legend:** ✅ Done · 🔧 In progress · 📌 Planned · 💭 Considering

---

## v1.0 — Launch

The initial public release: a complete, lossless optimizer for the three most
common web/photo formats, shipped as both an app and a CLI.

- ✅ Lossless **JPEG** optimization (drop EXIF/XMP/IPTC/comment marker segments;
  scan data copied byte-for-byte).
- ✅ Lossless **PNG** optimization (drop `tEXt`/`zTXt`/`iTXt`/`tIME`/`eXIf`
  chunks; re-deflate `IDAT` at zlib level 9 with identical pixels).
- ✅ Lossless **GIF** optimization (drop comment/non-essential application
  extensions; keep looping, frames and timing).
- ✅ ICC color profiles **kept by default**; stripping is strictly opt-in.
- ✅ Hard guarantees: pixels never change; output never larger than input.
- ✅ **`slimg` CLI** with `--dry-run`, `--backup`/`--copy`, `--report`/`-v`,
  `--keep-metadata`, `--strip-color`, `--no-recompress`, `--help`.
- ✅ **Slimg.app** SwiftUI GUI: drag-and-drop (files and recursive folders),
  per-file savings, advanced "what was removed" report, keep-originals backups.
- ✅ Advanced report with per-item byte accounting (app + CLI).
- ✅ Pixel-identity & "never grows" test suite (`SlimgCoreTests`).
- ✅ Pure Swift, links system `zlib`, no bundled third-party binaries; macOS 13+.
- ✅ `build-app.sh` assembles a universal (arm64 + x86_64) `Slimg.app`.

### Launch checklist

- ✅ Library, CLI and app build and pass `swift test`.
- 🔧 CI: build + test on push/PR (`.github/workflows/ci.yml`).
- 🔧 Release automation: tag → universal `Slimg.dmg` + `slimg-cli-macos.tar.gz`
  published to GitHub Releases (`.github/workflows/release.yml`).
- 🔧 Landing site at [slimg.app](https://slimg.app), deployed from `site/`
  (`.github/workflows/pages.yml`), download button → `releases/latest`.
- ✅ Docs: README, this roadmap, CONTRIBUTING, LICENSE (MIT), CHANGELOG.
- 📌 First tagged release `v1.0.0`.

> Items marked 🔧 are owned by the CI/site work happening in parallel; this
> roadmap tracks them so the launch picture stays honest.

---

## v1.1 — Polish & distribution

Smoothing the edges and making install frictionless, without adding any lossy
behavior.

- 📌 **Notarized, Developer-ID-signed builds** so the app launches without the
  right-click→Open dance. (The build script already supports a real signing
  identity and hardened runtime via `SLIMG_SIGN_IDENTITY`; this is wiring it
  into release CI.)
- 📌 **Homebrew distribution** — a cask for the app and/or a formula/tap for the
  CLI, so `brew install` works.
- 📌 **Batch progress** for large drops (aggregate progress while many files
  process), and clearer per-file states.
- 📌 **App menu & About** — proper menu bar, About window with version/build and
  links to the site, license and source.
- 💭 **Auto-update** via Sparkle or a lightweight GitHub-Releases check, so the
  app can offer new versions. (On by choice, never silent; no telemetry.)
- 💭 **Localization scaffolding** — extract UI strings so translations are
  possible.
- 💭 **CLI quality-of-life** — a `--quiet` flag and machine-readable
  (`--json`) report output for scripting.

---

## v1.2 and later — More reach

Carefully widening what Slimg can slim, and where you can invoke it — all still
lossless.

- 💭 **More formats, where a lossless win exists:**
  - **TIFF** — strip metadata IFDs / re-pack without touching pixel data.
  - **WebP** — lossless WebP re-pack and metadata (EXIF/XMP) stripping for
    lossless WebP files only.
  - **SVG** — minify markup (whitespace/metadata/editor cruft) without changing
    the rendered vector.
  - **HEIC** — metadata stripping where it can be done without re-encoding the
    image payload. (Lossy HEIC re-encode is **out of scope.**)
- 💭 **Finder integration** — a Quick Action / Services entry and a Shortcuts
  action so you can slim images from the right-click menu or an automation.
- 💭 **Parallel batch processing** — optimize multiple files concurrently for
  faster folder runs.
- 💭 **Optional advanced PNG strategies** (still strictly lossless) — e.g.
  trying multiple filter heuristics and keeping the smallest, or safe bit-depth
  / palette reductions that preserve every pixel exactly.
- 💭 **Mac App Store distribution** — would require sandboxing; the in-place,
  arbitrary-folder workflow needs to be reconciled with the sandbox first.

---

## Explicit non-goals

These are deliberate. Saying no keeps the promise on the tin.

- ❌ **Lossy compression / quantization (TinyPNG-style).** Re-encoding JPEGs,
  quantizing PNG palettes to fewer colors, or any "visually lossless" scheme
  that changes pixels contradicts Slimg's founding principle. Use a dedicated
  lossy tool for that.
- ❌ **Bundling external CLI binaries** (e.g. `pngquant`, `mozjpeg`, `gifsicle`,
  `optipng`). Slimg is pure Swift with the system `zlib` and stays that way:
  auditable, small, no third-party binaries to trust or update.
- ❌ **Servers, accounts, uploads, telemetry.** Slimg is 100% on-device and
  stays that way.
- ❌ **Stripping color profiles by default.** It can shift colors, so it remains
  strictly opt-in.

---

## Release process

1. Bump the version and update `CHANGELOG.md` (move `[Unreleased]` into a dated
   version section).
2. Tag the commit `vX.Y.Z` and push the tag.
3. CI (`release.yml`) builds the universal app and CLI, assembles
   **`Slimg.dmg`** and **`slimg-cli-macos.tar.gz`**, and publishes them to a
   **GitHub Release**. The app version is stamped from the tag
   (`SLIMG_VERSION` → bundled `Info.plist`).
4. The site's download button always points at
   [`releases/latest`](https://github.com/nicoschtein/slimg/releases/latest),
   so it picks up the new build automatically.

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to propose changes that fit this
roadmap.
