/* sndfile.h - a stand-in for libsndfile's header, for the core's build only.
 *
 * 86Box reads a CD's audio tracks that are separate sound files (a .cue
 * naming .wav or .flac files) through libsndfile. The core does not carry
 * it: sf_open answers that it cannot open the file, and cdrom_image.c then
 * refuses that track as it refuses a file it cannot read. Tracks stored raw
 * in a .bin, the usual case, never come here. */
#ifndef CHIMERA_SNDFILE_STUB_H
#define CHIMERA_SNDFILE_STUB_H

#include <stdint.h>
#include <stddef.h>
#include <wchar.h>

typedef int64_t sf_count_t;
typedef struct chimera_sndfile SNDFILE;
typedef struct {
	sf_count_t frames;
	int samplerate, channels, format, sections, seekable;
} SF_INFO;

#define SFM_READ 0x10

static inline SNDFILE *sf_open(const char *path, int mode, SF_INFO *info)
{ (void)path; (void)mode; (void)info; return NULL; }
static inline SNDFILE *sf_wchar_open(const wchar_t *path, int mode, SF_INFO *info)
{ (void)path; (void)mode; (void)info; return NULL; }
static inline int sf_close(SNDFILE *f) { (void)f; return 0; }
static inline sf_count_t sf_readf_short(SNDFILE *f, short *p, sf_count_t n)
{ (void)f; (void)p; (void)n; return 0; }
static inline sf_count_t sf_seek(SNDFILE *f, sf_count_t n, int whence)
{ (void)f; (void)n; (void)whence; return -1; }
static inline const char *sf_strerror(SNDFILE *f) { (void)f; return "this core reads no separate sound files"; }

#endif
