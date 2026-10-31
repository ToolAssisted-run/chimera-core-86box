/* zlib.h - a stand-in for zlib's header, for the core's build only.
 *
 * 86Box uses zlib in one place: cdrom_image.c inflates the header of an
 * encrypted Alcohol 120% / Daemon Tools image (.mdx, or an .mds whose tracks
 * are encrypted). The core does not carry zlib; inflateInit fails, so such an
 * image's header reads as zeros and the image is not read. Plain .mds/.mdf,
 * .iso, .cue/.bin and the rest never come here. */
#ifndef CHIMERA_ZLIB_STUB_H
#define CHIMERA_ZLIB_STUB_H

#define Z_NULL 0
#define Z_OK 0
#define Z_NO_FLUSH 0
#define Z_STREAM_ERROR (-2)

typedef struct {
	const unsigned char *next_in;
	unsigned avail_in;
	unsigned char *next_out;
	unsigned avail_out;
	void *zalloc, *zfree, *opaque;
} z_stream;

static inline int inflateInit(z_stream *s) { (void)s; return Z_STREAM_ERROR; }
static inline int inflate(z_stream *s, int flush) { (void)s; (void)flush; return Z_STREAM_ERROR; }
static inline int inflateEnd(z_stream *s) { (void)s; return Z_STREAM_ERROR; }

#endif
