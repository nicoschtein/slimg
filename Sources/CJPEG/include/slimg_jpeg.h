#ifndef SLIMG_JPEG_H
#define SLIMG_JPEG_H
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
/* Entropy-only recoding. Never decodes/re-encodes pixels. A successful result
 * is smaller and has verified identical quantized DCT coefficients and coding
 * interpretation. Memory is released with slimg_jpeg_free. */
unsigned char *slimg_jpeg_optimize(const unsigned char *bytes, size_t length,
                                  int progressive, size_t *output_length);
int slimg_jpeg_equal_coefficients(const unsigned char *a, size_t a_length,
                                 const unsigned char *b, size_t b_length);
void slimg_jpeg_free(void *bytes);
#ifdef __cplusplus
}
#endif
#endif
