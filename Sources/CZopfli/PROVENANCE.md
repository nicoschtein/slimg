# Google Zopfli

The unmodified C files in `upstream/` are from Google Zopfli 1.0.3, tag
`zopfli-1.0.3`, commit `bd64b2f0553d4f1ef4e6627647c5d9fc8c71ffc0`:

https://github.com/google/zopfli/tree/bd64b2f0553d4f1ef4e6627647c5d9fc8c71ffc0

Source archive:
https://codeload.github.com/google/zopfli/tar.gz/bd64b2f0553d4f1ef4e6627647c5d9fc8c71ffc0

Archive SHA-256:
`09a9732e11975455921a7ec22cad75ca42ed3ea4c9cbe3ccff09750a77e03bcb`

Only the zlib/DEFLATE compression implementation and its headers are included.
The gzip wrapper, command-line program, general format dispatcher, and ZopfliPNG
image transformations are excluded. `COPYING`, `CONTRIBUTORS`, and `README` are
unmodified upstream files. Zopfli is licensed under Apache-2.0; see `COPYING`.

`shim.c` and `include/czopfli.h` are Slimg additions. They limit input to 1 MiB,
use five iterations and at most five split blocks, and expose an allocation/free
interface. Slimg retains a result only if system zlib independently inflates it
to exactly the original filtered bytes and the complete PNG becomes smaller.
No separate executable, download at runtime, metadata rewrite, alpha rewrite,
or image quantization is involved.
