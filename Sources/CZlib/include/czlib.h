#ifndef CZLIB_H
#define CZLIB_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Inflate a complete zlib stream (header + DEFLATE + adler32).
/// Returns a malloc'd buffer (free with czlib_free) and writes the
/// decompressed length to *outLen. Returns NULL on error.
unsigned char *czlib_inflate(const unsigned char *src, size_t srcLen, size_t *outLen);
unsigned char *czlib_inflate_bounded(const unsigned char *src, size_t srcLen, size_t maximumSize, size_t *outLen);

/// Deflate raw bytes into a complete zlib stream at the given level (0-9).
/// Returns a malloc'd buffer (free with czlib_free) and writes the
/// compressed length to *outLen. Returns NULL on error.
unsigned char *czlib_deflate(const unsigned char *src, size_t srcLen, int level, size_t *outLen);
/// Strategy is zlib's 0...4 (default, filtered, Huffman-only, RLE, fixed).
unsigned char *czlib_deflate_strategy(const unsigned char *src, size_t srcLen, int level, int strategy, size_t *outLen);

void czlib_free(void *p);

#ifdef __cplusplus
}
#endif

#endif /* CZLIB_H */
