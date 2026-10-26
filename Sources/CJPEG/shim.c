#include "slimg_jpeg.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#include <setjmp.h>
#include "jpeglib.h"

#define SLIMG_JPEG_MAX_BLOCKS ((uint64_t)524288)
#define SLIMG_JPEG_MAX_SCANS 256

struct slimg_error {
    struct jpeg_error_mgr base;
    jmp_buf jump;
};
struct slimg_destination {
    struct jpeg_destination_mgr base;
    unsigned char *bytes;
    size_t capacity;
    size_t length;
};
struct slimg_state {
    struct jpeg_decompress_struct source;
    struct jpeg_decompress_struct verify;
    struct jpeg_compress_struct destination;
    struct slimg_error error;
    struct slimg_destination buffer;
    struct jpeg_progress_mgr progress;
};

static void fail(j_common_ptr info) {
    struct slimg_error *error = (struct slimg_error *)info->err;
    longjmp(error->jump, 1);
}
static void message(j_common_ptr info, int level) {
    /* Truncation and corrupt-data recovery warnings must be a no-op, not a
     * repaired output that silently changes coefficients. */
    if (level < 0) fail(info);
}
static void monitor(j_common_ptr info) {
    if (info->is_decompressor &&
        ((j_decompress_ptr)info)->input_scan_number > SLIMG_JPEG_MAX_SCANS) fail(info);
}
static void init_destination(j_compress_ptr info) {
    struct slimg_destination *buffer = (struct slimg_destination *)info->dest;
    buffer->base.next_output_byte = buffer->bytes;
    buffer->base.free_in_buffer = buffer->capacity;
}
static boolean full_destination(j_compress_ptr info) {
    /* Output cannot beat the input once its fixed-size buffer fills. */
    fail((j_common_ptr)info);
    return FALSE;
}
static void finish_destination(j_compress_ptr info) {
    struct slimg_destination *buffer = (struct slimg_destination *)info->dest;
    buffer->length = buffer->capacity - buffer->base.free_in_buffer;
}
static void cleanup(struct slimg_state *state) {
    if (state->source.mem) jpeg_destroy_decompress(&state->source);
    if (state->verify.mem) jpeg_destroy_decompress(&state->verify);
    if (state->destination.mem) jpeg_destroy_compress(&state->destination);
    free(state->buffer.bytes);
    free(state);
}
static struct slimg_state *new_state(void) {
    struct slimg_state *state = calloc(1, sizeof(*state));
    if (!state) return NULL;
    jpeg_std_error(&state->error.base);
    state->error.base.error_exit = fail;
    state->error.base.emit_message = message;
    state->source.err = &state->error.base;
    state->verify.err = &state->error.base;
    state->destination.err = &state->error.base;
    state->progress.progress_monitor = monitor;
    return state;
}
static int read_header(struct slimg_state *state, j_decompress_ptr source,
                       const unsigned char *bytes, size_t length, int markers) {
    if (!bytes || length < 4 || length > 128 * 1024 * 1024 ||
        bytes[0] != 255 || bytes[1] != 216 ||
        bytes[length - 2] != 255 || bytes[length - 1] != 217) return 0;
    jpeg_create_decompress(source);
    source->mem->max_memory_to_use = 128 * 1024 * 1024;
    source->progress = &state->progress;
    jpeg_mem_src(source, bytes, (unsigned long)length);
    if (markers) {
        for (int m = 0; m < 16; ++m) jpeg_save_markers(source, JPEG_APP0 + m, 0xFFFF);
        jpeg_save_markers(source, JPEG_COM, 0xFFFF);
    }
    if (jpeg_read_header(source, TRUE) != JPEG_HEADER_OK || source->data_precision != 8 ||
        source->arith_code || source->image_width == 0 || source->image_height == 0 ||
        source->num_components < 1 || source->num_components > 4) return 0;
    uint64_t blocks = 0;
    for (int i = 0; i < source->num_components; ++i) {
        jpeg_component_info *c = &source->comp_info[i];
        blocks += (uint64_t)c->width_in_blocks * c->height_in_blocks;
    }
    return blocks > 0 && blocks <= SLIMG_JPEG_MAX_BLOCKS;
}
static int equal(j_decompress_ptr a, jvirt_barray_ptr *ac,
                 j_decompress_ptr b, jvirt_barray_ptr *bc) {
    if (a->image_width != b->image_width || a->image_height != b->image_height ||
        a->data_precision != b->data_precision || a->num_components != b->num_components ||
        a->jpeg_color_space != b->jpeg_color_space) return 0;
    for (int i = 0; i < a->num_components; ++i) {
        jpeg_component_info *x = &a->comp_info[i], *y = &b->comp_info[i];
        if (x->component_id != y->component_id || x->h_samp_factor != y->h_samp_factor ||
            x->v_samp_factor != y->v_samp_factor || x->width_in_blocks != y->width_in_blocks ||
            x->height_in_blocks != y->height_in_blocks || !x->quant_table || !y->quant_table ||
            memcmp(x->quant_table->quantval, y->quant_table->quantval,
                   sizeof(x->quant_table->quantval))) return 0;
        for (JDIMENSION row = 0; row < x->height_in_blocks; ++row) {
            JBLOCKARRAY ra = (*a->mem->access_virt_barray)((j_common_ptr)a, ac[i], row, 1, FALSE);
            JBLOCKARRAY rb = (*b->mem->access_virt_barray)((j_common_ptr)b, bc[i], row, 1, FALSE);
            if (memcmp(ra[0], rb[0], x->width_in_blocks * sizeof(JBLOCK))) return 0;
        }
    }
    return 1;
}
unsigned char *slimg_jpeg_optimize(const unsigned char *bytes, size_t length,
                                  int progressive, size_t *output_length) {
    if (output_length) *output_length = 0;
    struct slimg_state *state = new_state();
    if (!state) return NULL;
    if (setjmp(state->error.jump)) { cleanup(state); return NULL; }
    if (!read_header(state, &state->source, bytes, length, 1)) { cleanup(state); return NULL; }
    jpeg_saved_marker_ptr header_tail = state->source.marker_list;
    while (header_tail && header_tail->next) header_tail = header_tail->next;
    jvirt_barray_ptr *coefficients = jpeg_read_coefficients(&state->source);
    /* Moving a marker from between/after scans into the header could change
     * interpretation in decoders that only inspect header metadata. */
    if ((header_tail && header_tail->next) || (!header_tail && state->source.marker_list)) {
        cleanup(state); return NULL;
    }
    if (!coefficients || !jpeg_input_complete(&state->source) ||
        state->source.src->bytes_in_buffer != 0) { cleanup(state); return NULL; }
    /* MPF offsets reference positions in the original file. Repacking without
     * updating its auxiliary-image index would invalidate those references. */
    for (jpeg_saved_marker_ptr m = state->source.marker_list; m; m = m->next) {
        if (m->marker == JPEG_APP0 + 2 && m->data_length >= 4 &&
            memcmp(m->data, "MPF\0", 4) == 0) { cleanup(state); return NULL; }
    }
    jpeg_create_compress(&state->destination);
    state->destination.mem->max_memory_to_use = 128 * 1024 * 1024;
    state->buffer.bytes = malloc(length);
    if (!state->buffer.bytes) { cleanup(state); return NULL; }
    state->buffer.capacity = length;
    state->buffer.base.init_destination = init_destination;
    state->buffer.base.empty_output_buffer = full_destination;
    state->buffer.base.term_destination = finish_destination;
    state->destination.dest = &state->buffer.base;
    jpeg_copy_critical_parameters(&state->source, &state->destination);
    state->destination.optimize_coding = TRUE;
    state->destination.arith_code = FALSE;
    state->destination.restart_interval = state->source.restart_interval;
    /* Copy original JFIF/Adobe markers instead of generating replacements. */
    state->destination.write_JFIF_header = FALSE;
    state->destination.write_Adobe_marker = FALSE;
    if (progressive) jpeg_simple_progression(&state->destination);
    jpeg_write_coefficients(&state->destination, coefficients);
    for (jpeg_saved_marker_ptr m = state->source.marker_list; m; m = m->next)
        jpeg_write_marker(&state->destination, m->marker, m->data, m->data_length);
    jpeg_finish_compress(&state->destination);
    if (state->buffer.length >= length ||
        !read_header(state, &state->verify, state->buffer.bytes, state->buffer.length, 0)) {
        cleanup(state); return NULL;
    }
    jvirt_barray_ptr *verified = jpeg_read_coefficients(&state->verify);
    if (!verified || !jpeg_input_complete(&state->verify) ||
        !equal(&state->source, coefficients, &state->verify, verified)) { cleanup(state); return NULL; }
    unsigned char *result = state->buffer.bytes;
    if (output_length) *output_length = state->buffer.length;
    state->buffer.bytes = NULL;
    cleanup(state);
    return result;
}
int slimg_jpeg_equal_coefficients(const unsigned char *a, size_t a_length,
                                 const unsigned char *b, size_t b_length) {
    struct slimg_state *state = new_state();
    if (!state) return 0;
    if (setjmp(state->error.jump)) { cleanup(state); return 0; }
    if (!read_header(state, &state->source, a, a_length, 0) ||
        !read_header(state, &state->verify, b, b_length, 0)) { cleanup(state); return 0; }
    jvirt_barray_ptr *ac = jpeg_read_coefficients(&state->source);
    jvirt_barray_ptr *bc = jpeg_read_coefficients(&state->verify);
    int result = ac && bc && jpeg_input_complete(&state->source) && jpeg_input_complete(&state->verify) &&
                 equal(&state->source, ac, &state->verify, bc);
    cleanup(state);
    return result;
}
void slimg_jpeg_free(void *bytes) { free(bytes); }
