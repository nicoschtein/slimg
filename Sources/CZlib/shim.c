#include "czlib.h"

#include <zlib.h>
#include <stdlib.h>
#include <string.h>

#define CZLIB_CHUNK 65536

unsigned char *czlib_inflate(const unsigned char *src, size_t srcLen, size_t *outLen) {
    if (outLen) *outLen = 0;
    z_stream s;
    memset(&s, 0, sizeof(s));
    if (inflateInit(&s) != Z_OK) {
        return NULL;
    }

    size_t cap = srcLen ? (srcLen * 4 + CZLIB_CHUNK) : CZLIB_CHUNK;
    unsigned char *out = (unsigned char *)malloc(cap);
    if (!out) {
        inflateEnd(&s);
        return NULL;
    }

    s.next_in = (Bytef *)src;
    s.avail_in = (uInt)srcLen;
    s.next_out = out;
    s.avail_out = (uInt)cap;

    for (;;) {
        if (s.avail_out == 0) {
            size_t used = cap;
            size_t ncap = cap * 2;
            unsigned char *n = (unsigned char *)realloc(out, ncap);
            if (!n) {
                free(out);
                inflateEnd(&s);
                return NULL;
            }
            out = n;
            s.next_out = out + used;
            s.avail_out = (uInt)(ncap - used);
            cap = ncap;
        }

        int ret = inflate(&s, Z_NO_FLUSH);
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

    if (outLen) *outLen = cap - s.avail_out;
    inflateEnd(&s);
    return out;
}

unsigned char *czlib_deflate(const unsigned char *src, size_t srcLen, int level, size_t *outLen) {
    if (outLen) *outLen = 0;
    if (level < 0 || level > 9) level = Z_BEST_COMPRESSION;

    z_stream s;
    memset(&s, 0, sizeof(s));
    if (deflateInit(&s, level) != Z_OK) {
        return NULL;
    }

    size_t cap = deflateBound(&s, (uLong)srcLen);
    if (cap == 0) cap = CZLIB_CHUNK;
    unsigned char *out = (unsigned char *)malloc(cap);
    if (!out) {
        deflateEnd(&s);
        return NULL;
    }

    s.next_in = (Bytef *)src;
    s.avail_in = (uInt)srcLen;
    s.next_out = out;
    s.avail_out = (uInt)cap;

    for (;;) {
        int ret = deflate(&s, Z_FINISH);
        if (ret == Z_STREAM_END) {
            break;
        }
        if (ret == Z_OK || ret == Z_BUF_ERROR) {
            if (s.avail_out == 0) {
                size_t used = cap;
                size_t ncap = cap * 2;
                unsigned char *n = (unsigned char *)realloc(out, ncap);
                if (!n) {
                    free(out);
                    deflateEnd(&s);
                    return NULL;
                }
                out = n;
                s.next_out = out + used;
                s.avail_out = (uInt)(ncap - used);
                cap = ncap;
            }
            continue;
        }
        free(out);
        deflateEnd(&s);
        return NULL;
    }

    if (outLen) *outLen = cap - s.avail_out;
    deflateEnd(&s);
    return out;
}

void czlib_free(void *p) {
    free(p);
}
