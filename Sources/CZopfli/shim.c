#include "include/czopfli.h"
#include "upstream/zlib_container.h"
#include <stdlib.h>

unsigned char *czopfli_compress(const unsigned char *input, size_t size, size_t *outputSize) {
    if (outputSize) *outputSize = 0;
    /* Zopfli has no cancellation API. Restrict work to 1 MiB and five iterations
       so an opt-in optimization cannot start an unbounded search on a huge PNG. */
    if (!input || !size || size > 1024 * 1024 || !outputSize) return NULL;
    ZopfliOptions options;
    ZopfliInitOptions(&options);
    options.numiterations = 5;
    options.blocksplittingmax = 5;
    unsigned char *output = NULL;
    ZopfliZlibCompress(&options, input, size, &output, outputSize);
    return output;
}

void czopfli_free(void *buffer) { free(buffer); }
