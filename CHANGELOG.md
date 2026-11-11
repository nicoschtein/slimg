# Changelog

All notable changes to Slimg are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- **JPEG orientation is preserved** when stripping metadata. Camera and phone
  photos that store their rotation only in the EXIF Orientation tag no longer
  appear rotated or mirrored after optimization: the EXIF block is replaced by a
  minimal one carrying just the Orientation (reported as "EXIF metadata (APP1),
  orientation kept"). Malformed or truncated EXIF segments are now left as-is.
- **JPEG Adobe RGB color is preserved** when stripping metadata. Photos from
  cameras set to Adobe RGB that embed no ICC profile mark their color space only
  in EXIF (Interoperability index "R03"); that marker is now kept in the minimal
  EXIF segment while color profiles are kept, so colors no longer shift toward
  sRGB. It is dropped when an ICC profile is embedded or with `--strip-color`.

## [1.1.0] - 2026-10-26

### Added

- **Seven optional lossless methods**, all disabled by default in the app and
  CLI: PNG filter/zlib strategy search, Zopfli, exact representation reductions,
  chunk/profile optimization, JPEG Huffman and progressive coefficient coding,
  and GIF LZW recompression with unchanged frame indices and animation controls.
- Pinned libjpeg-turbo and Google Zopfli C sources built into Slimg, with license
  notices included in app and CLI distributions. No external tools required.
- Native-precision PNG and independent ImageIO GIF/JPEG verification, savings
  fixtures, malformed-input checks, and default-off coverage.

- **HEIC/HEIF support** for iPhone photos in the app and CLI, including folder
  drops, the file picker and Finder document types. Uses macOS ImageIO to strip
  descriptive metadata without re-encoding image data, preserving orientation
  and color profiles. Unsupported layouts remain unchanged.

### Changed

- Release builds run the full test suite before packaging the app and CLI.
- The website documents all seven optional compression flags, their default-off
  behavior, format-specific features, and usage examples.

## [1.0.0] - 2026-06-15

Initial public release. Slimg is a lossless image optimizer for macOS — it
strips metadata and re-packs JPEG, PNG and GIF files so they get smaller without
ever changing a single pixel. The output decodes byte-for-byte identically to
the input and is never larger than the original.

### Added

- **Lossless JPEG optimization** — removes EXIF/XMP (APP1), IPTC/Photoshop
  (APP13), other APP segments and `COM` comments; keeps APP0 (JFIF), APP14
  (Adobe) and the ICC profile by default. Entropy-coded scan data is copied
  byte-for-byte.
- **Lossless PNG optimization** — removes `tEXt`/`zTXt`/`iTXt`/`tIME`/`eXIf`
  chunks and re-deflates the `IDAT` image data at zlib level 9 with identical
  decoded pixels; all rendering-relevant chunks are preserved.
- **Lossless GIF optimization** — removes comment and non-essential application
  extensions (e.g. XMP) while preserving the `NETSCAPE` looping extension,
  graphic-control extensions, color tables and frame timing.
- **Hard guarantees** — pixels are never altered and output is never larger than
  the input; if an optimizer can't beat the original, the original bytes are
  returned unchanged.
- **ICC color profiles kept by default** — stripping them is strictly opt-in,
  since it can shift colors.
- **`slimg` command-line tool** with `--dry-run`, `--backup`/`--copy`,
  `--report`/`-v`, `--keep-metadata`, `--strip-color`, `--no-recompress` and
  `-h`/`--help`, plus a per-file and total savings summary.
- **Slimg.app** — a native SwiftUI macOS app with drag-and-drop (files and
  recursive folders), per-file savings, and an advanced report showing exactly
  what was removed and how many bytes each item saved. Originals are backed up as
  `name.bak.ext` by default.
- **SlimgCore** library — the public `Slimg.optimize(_:options:)` API with the
  `OptimizationResult` / `OptimizationReport` types, shared by the CLI and app.
- **100% on-device** — no network, uploads, accounts or telemetry. Pure Swift,
  links the system `zlib`, no bundled third-party binaries. macOS 13+.
- **Test suite** enforcing pixel identity and the "never grows" guarantee.
- **Universal app bundling** via `Scripts/build-app.sh` (arm64 + x86_64).

[Unreleased]: https://github.com/nicoschtein/slimg/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/nicoschtein/slimg/compare/v1.0.0...v1.1.0
[1.0.0]: https://github.com/nicoschtein/slimg/releases/tag/v1.0.0
