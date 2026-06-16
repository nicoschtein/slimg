#include "czlib.h"

#include <zlib.h>
#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#define CZLIB_CHUNK 65536

/*
 * Decompression-bomb ceiling for inflate. A crafted zlib stream can expand by
 * roughly 1000:1, so an unbounded output buffer (cap *= 2 forever) lets a tiny
 * IDAT inflate to gigabytes and OOM/crash the process. We refuse to inflate
 * past CZLIB_INFLATE_MAX. Slimg only inflates a PNG's IDAT in order to
 * re-deflate it; if the real decompressed size exceeds this ceiling the caller
 * simply keeps the original file untouched, so the lossless guarantee holds.
 *
 * 512 MiB comfortably covers any sane real-world PNG's filtered scanlines
 * (e.g. a 16384x16384 RGBA image is ~1 GiB raw, well beyond what this tool is
 * meant to recompress) while bounding worst-case memory for a single file.
 */
#define CZLIB_INFLATE_MAX ((size_t)512 * 1024 * 1024)

/* zlib's avail_in/avail_out are uInt (typically 32-bit). Feed input in capped
 * windows and clamp the output window so neither field is ever truncated. */
#define CZLIB_UINT_MAX ((size_t)0xFFFFFFFFu)

unsigned char *czlib_inflate(const unsigned char *src, size_t srcLen, size_t *outLen) {
    if (outLen) *outLen = 0;
    if (src == NULL || srcLen == 0) {
        return NULL;
    }

    z_stream s;
    memset(&s, 0, sizeof(s));
    if (inflateInit(&s) != Z_OK) {
        return NULL;
    }

    /* Initial guess: 4x input, overflow-safe, clamped to the bomb ceiling. */
    size_t cap;
    if (srcLen > (SIZE_MAX - CZLIB_CHUNK) / 4) {
        cap = CZLIB_INFLATE_MAX;
    } else {
        cap = srcLen * 4 + CZLIB_CHUNK;
        if (cap > CZLIB_INFLATE_MAX) cap = CZLIB_INFLATE_MAX;
    }
    unsigned char *out = (unsigned char *)malloc(cap);
    if (!out) {
        inflateEnd(&s);
        return NULL;
    }

    s.next_in = (Bytef *)src;
    s.next_out = out;
    /* avail_in/avail_out are refreshed each iteration to respect uInt limits. */
    size_t inPos = 0;
    size_t produced = 0; /* bytes written into out so far */

    for (;;) {
        /* Grow the output buffer when full, capped by the bomb ceiling. */
        if (produced == cap) {
            if (cap >= CZLIB_INFLATE_MAX) {
                /* Reached the ceiling but the stream is not done: refuse. */
                free(out);
                inflateEnd(&s);
                return NULL;
            }
            size_t ncap;
            if (cap > CZLIB_INFLATE_MAX / 2) {
                ncap = CZLIB_INFLATE_MAX;
            } else {
                ncap = cap * 2;
            }
            unsigned char *n = (unsigned char *)realloc(out, ncap);
            if (!n) {
                free(out);
                inflateEnd(&s);
                return NULL;
            }
            out = n;
            cap = ncap;
        }

        /* Clamp the input/output windows to uInt range. */
        size_t inRemain = srcLen - inPos;
        size_t outRemain = cap - produced;
        s.next_in = (Bytef *)(src + inPos);
        s.avail_in = (uInt)(inRemain > CZLIB_UINT_MAX ? CZLIB_UINT_MAX : inRemain);
        s.next_out = out + produced;
        s.avail_out = (uInt)(outRemain > CZLIB_UINT_MAX ? CZLIB_UINT_MAX : outRemain);

        uInt beforeIn = s.avail_in;
        uInt beforeOut = s.avail_out;

        int ret = inflate(&s, Z_NO_FLUSH);

        inPos += (size_t)(beforeIn - s.avail_in);
        produced += (size_t)(beforeOut - s.avail_out);

        if (ret == Z_STREAM_END) {
            break;
        }
        if (ret == Z_OK) {
            continue;
        }
        if (ret == Z_BUF_ERROR && s.avail_out == 0) {
            continue; /* needs a bigger output buffer; grown at top of loop */
        }
        /* Z_BUF_ERROR with room left means truncated input; any other code is fatal. */
        free(out);
        inflateEnd(&s);
        return NULL;
    }

    if (outLen) *outLen = produced;
    inflateEnd(&s);
    return out;
}

unsigned char *czlib_deflate(const unsigned char *src, size_t srcLen, int level, size_t *outLen) {
    if (outLen) *outLen = 0;
    if (src == NULL && srcLen != 0) {
        return NULL;
    }
    if (level < 0 || level > 9) level = Z_BEST_COMPRESSION;

    z_stream s;
    memset(&s, 0, sizeof(s));
    if (deflateInit(&s, level) != Z_OK) {
        return NULL;
    }

    size_t cap = deflateBound(&s, (uLong)srcLen);
    if (cap == 0 || cap < CZLIB_CHUNK) cap = CZLIB_CHUNK;
    unsigned char *out = (unsigned char *)malloc(cap);
    if (!out) {
        deflateEnd(&s);
        return NULL;
    }

    /* avail_in/avail_out are uInt; feed input and drain output in <=uInt
     * windows so a >4 GiB buffer is never truncated into a 32-bit field. */
    size_t inPos = 0;
    size_t produced = 0;

    for (;;) {
        if (produced == cap) {
            if (cap > SIZE_MAX / 2) {
                free(out);
                deflateEnd(&s);
                return NULL;
            }
            size_t ncap = cap * 2;
            unsigned char *n = (unsigned char *)realloc(out, ncap);
            if (!n) {
                free(out);
                deflateEnd(&s);
                return NULL;
            }
            out = n;
            cap = ncap;
        }

        size_t inRemain = srcLen - inPos;
        size_t outRemain = cap - produced;
        s.next_in = (Bytef *)(src + inPos);
        s.avail_in = (uInt)(inRemain > CZLIB_UINT_MAX ? CZLIB_UINT_MAX : inRemain);
        s.next_out = out + produced;
        s.avail_out = (uInt)(outRemain > CZLIB_UINT_MAX ? CZLIB_UINT_MAX : outRemain);

        /* Only request Z_FINISH once all input has been handed to zlib;
         * otherwise deflate may report Z_STREAM_END prematurely. */
        int flush = (inPos + (size_t)s.avail_in >= srcLen) ? Z_FINISH : Z_NO_FLUSH;

        uInt beforeIn = s.avail_in;
        uInt beforeOut = s.avail_out;

        int ret = deflate(&s, flush);

        inPos += (size_t)(beforeIn - s.avail_in);
        produced += (size_t)(beforeOut - s.avail_out);

        if (ret == Z_STREAM_END) {
            break;
        }
        if (ret == Z_OK || ret == Z_BUF_ERROR) {
            continue; /* output buffer grown at top of loop when full */
        }
        free(out);
        deflateEnd(&s);
        return NULL;
    }

    if (outLen) *outLen = produced;
    deflateEnd(&s);
    return out;
}

void czlib_free(void *p) {
    free(p);
}
