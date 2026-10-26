# Third-party notices

Slimg's application and command-line tool include the libraries below, compiled
from the pinned source copies in this repository. No separate executables are
invoked and no runtime downloads are performed. Slimg's original code remains
under its MIT license; upstream code retains its own notices and licenses.

## libjpeg-turbo 3.2.0

This software is based in part on the work of the Independent JPEG Group.

- Source: <https://github.com/libjpeg-turbo/libjpeg-turbo>
- Vendored files, configuration and provenance: `Sources/CJPEG/`
- License terms: `Sources/CJPEG/LICENSE.md` and `Sources/CJPEG/README.ijg`
- Used for copying existing JPEG coefficients into optimized Huffman/progressive
  representations. Pixel re-encoding is not used.

## Google Zopfli 1.0.3

- Source: <https://github.com/google/zopfli>
- Pinned commit: `bd64b2f0553d4f1ef4e6627647c5d9fc8c71ffc0`
- Vendored files and provenance: `Sources/CZopfli/`
- License: Apache License 2.0, reproduced in `Sources/CZopfli/COPYING`
- Used for optional DEFLATE/zlib compression of unchanged PNG scanline bytes.

## System zlib

Slimg links the zlib supplied by macOS. The zlib license and documentation are
available at <https://zlib.net/>.

The build script copies this notice and the complete vendored license files into
`Slimg.app/Contents/Resources/ThirdPartyLicenses/`. CLI release archives also
include these notices and licenses.
