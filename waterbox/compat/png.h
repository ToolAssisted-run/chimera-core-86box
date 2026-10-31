/* png.h - a stand-in for libpng's header, for the core's build only.
 *
 * 86Box's video.c writes screenshots with libpng. A core never writes a
 * screenshot (the frontend takes its own from the picture the core hands
 * over), so the core carries no libpng: every call here fails the way
 * libpng's do when they cannot start, and video.c then logs and gives up. */
#ifndef CHIMERA_PNG_STUB_H
#define CHIMERA_PNG_STUB_H

#include <stddef.h>
#include <stdio.h>

typedef unsigned char png_byte;
typedef png_byte *png_bytep;
typedef struct chimera_png_struct *png_structp;
typedef struct chimera_png_info *png_infop;

#define PNG_LIBPNG_VER_STRING "chimera-none"
#define PNG_COLOR_TYPE_RGB 2
#define PNG_INTERLACE_NONE 0
#define PNG_COMPRESSION_TYPE_BASE 0
#define PNG_FILTER_TYPE_BASE 0

static inline png_structp png_create_write_struct(const char *v, void *a, void *b, void *c)
{ (void)v; (void)a; (void)b; (void)c; return NULL; }
static inline png_infop png_create_info_struct(png_structp p) { (void)p; return NULL; }
static inline void png_destroy_write_struct(png_structp *p, png_infop *i) { (void)p; (void)i; }
static inline void png_init_io(png_structp p, FILE *f) { (void)p; (void)f; }
static inline void png_set_IHDR(png_structp p, png_infop i, unsigned w, unsigned h, int d,
                                int c, int il, int cm, int f)
{ (void)p; (void)i; (void)w; (void)h; (void)d; (void)c; (void)il; (void)cm; (void)f; }
static inline void png_write_info(png_structp p, png_infop i) { (void)p; (void)i; }
static inline size_t png_get_rowbytes(png_structp p, png_infop i) { (void)p; (void)i; return 0; }
static inline void png_write_image(png_structp p, png_bytep *rows) { (void)p; (void)rows; }
static inline void png_write_end(png_structp p, png_infop i) { (void)p; (void)i; }

#endif
