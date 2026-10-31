/* chimera-audio.c - the frame's sound, from 86Box's streams.
 *
 * 86Box hands its sound over in blocks, each stream at its own rate and when
 * its own timer says (sound.c): the cards' main stream at 48000 Hz in 20 ms
 * blocks, the FM synthesizers' at 49716 Hz, wavetables' and CD audio's at
 * 44100 Hz. Chimera takes one stream a frame at one rate, 48000 Hz here.
 *
 * The main stream is the frame's sound as it arrives. Each other stream is
 * converted to 48000 Hz (linear interpolation, in integers) and added to the
 * main stream DELAY samples later than the moment it stands for: a block of
 * the other stream always arrives before the main samples it is added to
 * (its blocks are at most 28 ms long, DELAY is 43 ms), so nothing is added
 * late and nothing is dropped, whatever the order the timers fire in. The
 * cost is that FM music is 43 ms behind the cards' own sound - inaudible,
 * and the same in every run.
 *
 * Everything here is ordinary memory, so a state carries it: a run that
 * loads a state mixes on exactly as one that did not.
 */
#include <stdint.h>
#include <string.h>

#include "chimera.h"

#define OUT_RATE 48000
#define RING     8192            /* a power of two, more than DELAY + a block */
#define DELAY    2048

/* the frame's sound, handed to the frontend */
#define AUDIO_CAP 48000
static int16_t g_out[AUDIO_CAP * 2];
static int g_outPairs;

/* what the other streams have to add, by the main stream's sample index */
static int32_t g_ring[RING * 2];
static uint64_t g_mainIndex;     /* main stream samples handed over so far */

typedef struct {
	int rate, block;             /* Hz, pairs a block */
	uint64_t in;                 /* input samples taken so far */
	uint64_t out;                /* 48 kHz samples made so far */
	int16_t prev[2];             /* the input sample before this block */
} stream_t;

static stream_t g_stream[CHIMERA_STREAMS] = {
	[CHIMERA_STREAM_SOUND] = { 48000, 960 },
	[CHIMERA_STREAM_MUSIC] = { 49716, 49716 / 36 },
	[CHIMERA_STREAM_WAVETABLE] = { 44100, 44100 / 45 },
	[CHIMERA_STREAM_CD] = { 44100, 44100 / 10 },
};

int16_t *chimera_audio_buffer(void) { return g_out; }
int chimera_audio_pairs(void) { return g_outPairs; }
void chimera_audio_frame_start(void) { g_outPairs = 0; }

static int16_t clamp16(int32_t v) { return (int16_t)(v > 32767 ? 32767 : v < -32768 ? -32768 : v); }

void chimera_audio_take(int stream, const int16_t *buf)
{
	stream_t *s = &g_stream[stream];
	if (stream == CHIMERA_STREAM_SOUND) {
		for (int i = 0; i < s->block; i++, g_mainIndex++) {
			int32_t *r = &g_ring[(g_mainIndex % RING) * 2];
			if (g_outPairs < AUDIO_CAP) {
				g_out[g_outPairs * 2] = clamp16(buf[i * 2] + r[0]);
				g_out[g_outPairs * 2 + 1] = clamp16(buf[i * 2 + 1] + r[1]);
				g_outPairs++;
			}
			r[0] = r[1] = 0;
		}
		return;
	}
	/* Output sample k stands for the time k/48000, which is the input
	 * position k*rate/48000: between input samples j and j+1 with j its
	 * whole part. This block holds inputs s->in .. s->in + block - 1, and
	 * s->prev is input s->in - 1. Every output whose position falls in
	 * (in - 1, in + block - 1] is made now. */
	const uint64_t first = s->in, last = s->in + (uint64_t)s->block - 1;
	for (;;) {
		const uint64_t num = s->out * (uint64_t)s->rate;   /* position * 48000 */
		const uint64_t j = num / OUT_RATE, frac = num % OUT_RATE;
		if (j >= last)
			break;
		int16_t a[2], b[2];
		for (int c = 0; c < 2; c++) {
			a[c] = (j + 1 == first || j < first) ? s->prev[c] : buf[(j - first) * 2 + c];
			b[c] = buf[(j + 1 - first) * 2 + c];
		}
		int32_t *r = &g_ring[((s->out + DELAY) % RING) * 2];
		for (int c = 0; c < 2; c++)
			r[c] += (int32_t)(((int64_t)a[c] * (int64_t)(OUT_RATE - frac) + (int64_t)b[c] * (int64_t)frac) / OUT_RATE);
		s->out++;
	}
	s->prev[0] = buf[(s->block - 1) * 2];
	s->prev[1] = buf[(s->block - 1) * 2 + 1];
	s->in += (uint64_t)s->block;
}
