#ifndef SLIMG_CZOPFLI_H
#define SLIMG_CZOPFLI_H
#include <stddef.h>

/// Bounded, five-iteration Zopfli zlib compression. Returns NULL for unsupported
/// inputs. The caller owns the returned buffer and frees it with czopfli_free.
unsigned char *czopfli_compress(const unsigned char *input, size_t size, size_t *outputSize);
void czopfli_free(void *buffer);
#endif
