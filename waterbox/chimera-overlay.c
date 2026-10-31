/* chimera-overlay.c - writable disks over read-only files.
 *
 * The frontend mounts every file of a project read-only, and the native
 * reference must behave as the sandbox does. A disk image 86Box opens for
 * writing (a floppy, a hard disk) is therefore given a stream over the
 * mounted file in which the bytes written are kept in the machine's own
 * memory, 4 KiB at a time, and read back from there; everything not written
 * is read from the file. So the user's file is never changed, a state
 * carries exactly what was written (the blocks are ordinary memory), and an
 * image of gigabytes costs nothing until the machine writes to it.
 *
 * An overlay belongs to the file's name for the whole session: 86Box closes
 * and reopens its images (a hard reset, a disk swapped back in), and what the
 * machine wrote is still there when it does. (After the PCem core's
 * pcem-hdd.c, there written against PCem's hard disk code; here a stdio
 * stream, which both C libraries make with fopencookie.)
 */
#define _GNU_SOURCE
#include <errno.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

#include "chimera.h"

#define BLOCK 4096
#define MAX_OVERLAYS 16

typedef struct {
	char name[256];
	FILE *base;           /* the mounted file, read-only */
	int64_t base_size;
	int64_t size;         /* grows when the machine writes past the end */
	uint8_t **blocks;     /* NULL where nothing was written */
	int64_t nblocks;
	int64_t written;      /* blocks held */
} overlay_t;

static overlay_t g_overlays[MAX_OVERLAYS];
static int g_count;

typedef struct {
	overlay_t *o;
	int64_t pos;
} stream_t;

static int grow(overlay_t *o, int64_t blocks)
{
	if (blocks <= o->nblocks)
		return 1;
	int64_t n = o->nblocks ? o->nblocks : 64;
	while (n < blocks)
		n *= 2;
	uint8_t **b = realloc(o->blocks, (size_t)n * sizeof *b);
	if (!b)
		return 0;
	memset(b + o->nblocks, 0, (size_t)(n - o->nblocks) * sizeof *b);
	o->blocks = b;
	o->nblocks = n;
	return 1;
}

/* a block's bytes as they stand: written ones from memory, the rest from
 * the file (zeros past its end) */
static void read_block(overlay_t *o, int64_t i, uint8_t *out)
{
	if (i < o->nblocks && o->blocks[i]) {
		memcpy(out, o->blocks[i], BLOCK);
		return;
	}
	memset(out, 0, BLOCK);
	int64_t off = i * BLOCK;
	if (off < o->base_size && o->base) {
		int64_t n = o->base_size - off < BLOCK ? o->base_size - off : BLOCK;
		if (fseeko(o->base, off, SEEK_SET) == 0)
			(void)!fread(out, 1, (size_t)n, o->base);
	}
}

static ssize_t s_read(void *c, char *buf, size_t size)
{
	stream_t *s = c;
	overlay_t *o = s->o;
	size_t done = 0;
	uint8_t blk[BLOCK];
	while (done < size && s->pos < o->size) {
		int64_t i = s->pos / BLOCK, at = s->pos % BLOCK;
		int64_t n = BLOCK - at;
		if ((int64_t)(size - done) < n)
			n = (int64_t)(size - done);
		if (o->size - s->pos < n)
			n = o->size - s->pos;
		read_block(o, i, blk);
		memcpy(buf + done, blk + at, (size_t)n);
		done += (size_t)n;
		s->pos += n;
	}
	return (ssize_t)done;
}

static ssize_t s_write(void *c, const char *buf, size_t size)
{
	stream_t *s = c;
	overlay_t *o = s->o;
	size_t done = 0;
	while (done < size) {
		int64_t i = s->pos / BLOCK, at = s->pos % BLOCK;
		int64_t n = BLOCK - at;
		if ((int64_t)(size - done) < n)
			n = (int64_t)(size - done);
		if (!grow(o, i + 1)) {
			errno = ENOSPC;
			return done ? (ssize_t)done : -1;
		}
		if (!o->blocks[i]) {
			uint8_t *b = malloc(BLOCK);
			if (!b) {
				errno = ENOSPC;
				return done ? (ssize_t)done : -1;
			}
			read_block(o, i, b);
			o->blocks[i] = b;
			o->written++;
		}
		memcpy(o->blocks[i] + at, buf + done, (size_t)n);
		done += (size_t)n;
		s->pos += n;
		if (s->pos > o->size)
			o->size = s->pos;
	}
	return (ssize_t)done;
}

static int s_seek(void *c, off_t *offset, int whence)
{
	stream_t *s = c;
	int64_t to = whence == SEEK_SET ? *offset : whence == SEEK_CUR ? s->pos + *offset : s->o->size + *offset;
	if (to < 0) {
		errno = EINVAL;
		return -1;
	}
	s->pos = to;
	*offset = to;
	return 0;
}

static int s_close(void *c)
{
	free(c);   /* the overlay stays: it is the disk's, for the session */
	return 0;
}

/* A stream over the mounted file `name` that takes writes, or NULL when
 * there is no such file. */
FILE *chimera_overlay_open(const char *name)
{
	overlay_t *o = NULL;
	for (int i = 0; i < g_count; i++)
		if (!strcmp(g_overlays[i].name, name))
			o = &g_overlays[i];
	if (!o) {
		FILE *base = fopen(name, "rb");
		if (!base || g_count >= MAX_OVERLAYS) {
			if (base)
				fclose(base);
			return NULL;
		}
		o = &g_overlays[g_count++];
		memset(o, 0, sizeof *o);
		snprintf(o->name, sizeof o->name, "%s", name);
		o->base = base;
		fseeko(base, 0, SEEK_END);
		o->base_size = o->size = ftello(base);
	}
	stream_t *s = calloc(1, sizeof *s);
	if (!s)
		return NULL;
	s->o = o;
	cookie_io_functions_t io = { s_read, s_write, s_seek, s_close };
	FILE *f = fopencookie(s, "r+", io);
	if (!f)
		free(s);
	return f;
}

/* what the machine wrote, for the tests and the save data */
int chimera_overlay_count(void) { return g_count; }
const char *chimera_overlay_name(int i) { return i >= 0 && i < g_count ? g_overlays[i].name : NULL; }
int64_t chimera_overlay_size(int i) { return i >= 0 && i < g_count ? g_overlays[i].size : 0; }
int64_t chimera_overlay_blocks(int i) { return i >= 0 && i < g_count ? g_overlays[i].written : 0; }

/* the whole image as it stands, from `offset`, into `out` */
int64_t chimera_overlay_read(int i, int64_t offset, uint8_t *out, int64_t len)
{
	if (i < 0 || i >= g_count || offset < 0 || len <= 0)
		return 0;
	stream_t s = { &g_overlays[i], offset };
	return (int64_t)s_read(&s, (char *)out, (size_t)len);
}
