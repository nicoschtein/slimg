# Contributing to Slimg

Thanks for your interest in Slimg. Contributions of all kinds are welcome — bug
reports, format support, UX improvements, tests, and docs. This guide covers how
to set things up, how the project is organized, and the one rule that never
bends.

## The lossless golden rule

> **Slimg never changes a pixel, and never produces a larger file.**

Every optimizer must be byte-for-byte lossless: re-decoding the output has to
yield exactly the same pixels as the input, and the output must never be larger
than the input. This is the whole reason Slimg exists.

In practice this means:

- **Pixel-identity tests are the gate.** `Tests/SlimgCoreTests` decodes the
  original and the optimized image to raw RGBA and asserts they are identical,
  and asserts `optimizedSize <= originalSize`. **A PR that breaks these tests
  will not be merged.**
- **When in doubt, bail out.** If an optimizer hits something it doesn't fully
  understand, it must return `nil` and let the caller keep the original bytes
  verbatim. A file Slimg can't parse confidently must never be corrupted.
- **Color profiles are kept by default.** Stripping ICC profiles can shift
  colors, so it stays strictly opt-in (`--strip-color` / the Settings toggle).
- **No lossy anything.** Re-encoding pixels, palette quantization, or
  "visually lossless" tricks are out of scope — see the
  [non-goals](ROADMAP.md#explicit-non-goals).

## Prerequisites

- **macOS 13 or newer.**
- **Xcode 15+** (a Swift 5.9+ toolchain). Slimg builds with current Swift
  releases as well. The package declares `swift-tools-version: 5.9`.
- Slimg links **system `zlib`** (`-lz`) and compiles pinned, vendored
  libjpeg-turbo and Google Zopfli C sources. There are no packages to fetch or
  external command-line tools required. Preserve upstream notices and source
  provenance when updating these libraries; see `THIRD_PARTY_NOTICES.md`.

## Build, test, run

```sh
git clone https://github.com/nicoschtein/slimg.git
cd slimg

swift build              # build everything (library, CLI, app target)
swift test               # run the lossless test suite — must stay green
swift run slimg --help   # run the CLI from source

# Build the double-clickable app bundle:
./Scripts/build-app.sh                       # release Slimg.app
./Scripts/build-app.sh debug                 # debug build
./Scripts/build-app.sh release --universal   # arm64 + x86_64

# Optional: sign with a real Developer ID for a notarization-ready bundle:
SLIMG_SIGN_IDENTITY="Developer ID Application: …" ./Scripts/build-app.sh
```

`build-app.sh` assembles `Slimg.app` in the repo root; `open Slimg.app` launches
it. Without a signing identity it falls back to an ad-hoc signature so the app
still runs locally.

## Project structure

```
Sources/
  SlimgCore/    The engine. Slimg.swift (public API, format detection, the
                "never grows" safety net) + JPEGOptimizer / PNGOptimizer /
                GIFOptimizer / HEICOptimizer + Zlib.swift (zlib wrapper).
  CZlib/        C shim + modulemap that links the system zlib.
  CJPEG/        Vendored libjpeg-turbo + bounded coefficient-copy bridge.
  CZopfli/      Vendored Google Zopfli + bounded compression bridge.
  slimg/        CLI: main.swift (arg parsing, file I/O, report printing).
  SlimgApp/     SwiftUI app: SlimgApp (entry), ContentView, OptimizerModel
                (processing + backups), SettingsView, Theme/BrandMark.
Tests/
  SlimgCoreTests/   Pixel-identity, "never grows", report and zlib round-trip
                    tests. This is the golden-rule gate.
Scripts/
  build-app.sh      Assembles Slimg.app from the SwiftPM build product.
Resources/          Info.plist and the app icon.
brand/              Brand guidelines (BRAND.md), logomark, wordmark, icon.
site/               Landing page sources for slimg.app.
```

The public API lives in `Sources/SlimgCore/Slimg.swift`:
`Slimg.optimize(_:options:)` returns an `OptimizationResult` with the new bytes,
detected `ImageFormat`, original/optimized sizes, and an `OptimizationReport`
listing every `RemovedItem` (kind + label + bytes). Both the CLI and the app
are thin shells over this.

## Adding a format optimizer

Each format optimizer is a small enum with a single
`optimize(_:options:) -> OptimizerOutput?` entry point. To add one (say, TIFF):

1. **Create** `Sources/SlimgCore/TIFFOptimizer.swift` following the existing
   ones as a template. Validate the magic bytes first; parse the container
   yourself or use an API that guarantees a lossless compressed-data copy;
   **return `nil` on anything unexpected.**
2. **Strip only non-pixel data.** Drop metadata, re-pack/re-deflate the existing
   compressed data only if the result is verifiably smaller and decodes
   identically. Never touch the pixel payload.
3. **Build a report.** Append a `RemovedItem` (with an existing `RemovalKind`,
   or add a new case) for each thing you remove or shrink, with an accurate byte
   count.
4. **Wire it up.** Add a case to `ImageFormat`, teach `Slimg.detectFormat` the
   magic bytes, and dispatch to your optimizer in `Slimg.optimize`. The
   "never grows" safety net in `Slimg.optimize` already protects you: if your
   output isn't smaller, the original is returned untouched.
5. **Test it.** Add pixel-identity and "never grows" tests in
   `SlimgCoreTests`, mirroring the JPEG/PNG cases (encode with metadata,
   optimize, decode both to RGBA, assert equal; assert the file shrank and
   metadata is gone).
6. **Surface it.** Add the new extension(s) to the app's supported set and the
   open-panel content types, and mention the format in the README and
   `--help` text.

If the format genuinely has no lossless win available, it's fine to leave it as
an explicit non-goal rather than ship a lossy path.

## Coding style

- Follow standard Swift conventions and match the surrounding code; keep
  `swift build` warning-clean.
- The core (`SlimgCore`) is platform-agnostic Foundation/C — keep AppKit/SwiftUI
  out of it. UI code stays in `SlimgApp`.
- Prefer small, auditable byte-level parsing with clear comments explaining
  *why* a segment/chunk is kept or dropped (see the headers in the existing
  optimizers for the tone).
- Use monospaced digits for byte/percent figures in UI, per `brand/BRAND.md`.

## Commits & pull requests

- Branch off `main`; keep PRs focused on one change.
- Write clear, imperative commit messages (e.g. "Strip APP13 IPTC from JPEG").
- In the PR description, say what you changed and **how losslessness is
  preserved**, and confirm `swift test` passes locally.
- New behavior needs tests — especially anything touching the optimizers.
- Be kind and concrete in reviews and issues.

## Reporting bugs & features

Open a GitHub issue. For bugs, include macOS version, Slimg version, the format,
and (if you can share it) a sample file — a file that gets corrupted, grows, or
has its pixels changed is the highest-priority kind of bug.

## Reporting security issues

**Do not** open a public issue for security problems. See
[SECURITY.md](SECURITY.md) for how to report privately. A way to make Slimg
corrupt, grow, or alter the pixels of a file counts as a security-relevant
correctness bug and is taken seriously.

## License

By contributing, you agree that your contributions are licensed under the
project's [MIT License](LICENSE).
