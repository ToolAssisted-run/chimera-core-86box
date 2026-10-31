/* What both runners of the tests do with the core once they have its
 * exports: the native one (run-native.c) calls them directly, the sandboxed
 * one (run-wbx.c) through miniBox. One file, so that the two runs are asked
 * the same things in the same order. (After chimera-core-fuse's.)
 *
 *   <runner> ... [--frames N] [--every K] [--set NAME=VALUE]...
 *                [--key F:N:INDEX]... [--axis F:N:INDEX:VALUE]...
 *                [--rerecord] [--save-state FILE --at F] [--state FILE]
 *                [--ppm FILE [--ppm-at F]] [--dump-ram FILE] [--digests FILE]
 *
 * --set NAME=VALUE  one of the package's settings (machine, cpuFamily, ...)
 * --key F:N:INDEX   from frame F (the first is 1) for N frames, the button
 *                   of that index in the package's declaration is held
 * --axis F:N:INDEX:VALUE   the same for an axis
 * --every K         a line of digest every K frames, and always one at the end
 * --digests FILE    a line a frame: the frame, the machine's clock, the
 *                   CPU's cycles, the picture's hash and the frame's loudest
 *                   sample - the stream two runs are compared by
 * --rerecord        a state saved and loaded before every frame (sandbox)
 * --save-state FILE --at F   after frame F, save a state to FILE and stop
 * --state FILE      carry on from a state another process saved
 * --ppm FILE [--ppm-at F]    the picture after frame F (the last one without
 *                   --ppm-at), as a file a person can look at
 * --dump-ram FILE   the machine's memory after the run
 * --stall-ms MS     (native) sleep this long on the host before every frame:
 *                   the machine must not notice
 */
#ifndef CHIMERA_86BOX_GATE_HARNESS_H_
#define CHIMERA_86BOX_GATE_HARNESS_H_

#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

struct harness_core {
	int (*Init)(void);
	const char *(*GetLoadError)(void);
	void (*FrameAdvance)(uint64_t);
	void (*SetButton)(int32_t, int32_t);
	void (*SetAxis)(int32_t, int32_t);
	int (*InputWasRead)(void);
	int16_t *(*GetAudio)(void);
	int (*GetAudioSampleCount)(void);
	uint32_t *(*GetVideoBgra)(void);
	int (*GetVideoWidth)(void);
	int (*GetVideoHeight)(void);
	int (*GetVsyncNumerator)(void);
	int (*GetVsyncDenominator)(void);
	uint8_t *(*GetMemoryDomainPtr)(int);
	int64_t (*GetMemoryDomainSize)(int);
	const char *(*DebugMachine)(void);
	uint64_t (*GetMachineMs)(void);
	uint64_t (*GetCpuCycles)(void);
	/* the sandbox's; null natively */
	int (*seal)(void);
	int (*save)(uint8_t **buf, size_t *len);
	int (*load)(const uint8_t *buf, size_t len);
};

#define HARNESS_MAX_EVENTS 4096
struct harness_event { uint64_t from, count; int32_t index, value; int axis; };
struct harness_opts {
	uint64_t frames, every, save_at, ppm_at, stall_ms;
	int rerecord;
	char settings[4096];      /* as the options give them, the object still open */
	char settings_json[4104]; /* the settings a runner hands the core, as the frontend would */
	const char *save_state, *state, *ppm, *dump_ram, *digests;
	struct harness_event ev[HARNESS_MAX_EVENTS];
	int events;
};

/* The options from argv[first...] that are the harness's; the runner's own
 * (--roms, --file) are left for it: a callback says whether it took one. */
typedef int (*harness_own_option)(const char *name, const char *value);

static int harness_parse(int argc, char **argv, int first, struct harness_opts *o, harness_own_option own)
{
	memset(o, 0, sizeof *o);
	o->frames = 300;
	strcpy(o->settings, "{");
	for (int i = first; i < argc; i++) {
		const char *a = argv[i];
		if (!strcmp(a, "--rerecord")) { o->rerecord = 1; continue; }
		if (i + 1 >= argc) {
			fprintf(stderr, "%s wants a value, or is not an option\n", a);
			return 0;
		}
		const char *v = argv[++i];
		if (!strcmp(a, "--frames")) o->frames = strtoull(v, NULL, 10);
		else if (!strcmp(a, "--every")) o->every = strtoull(v, NULL, 10);
		else if (!strcmp(a, "--at")) o->save_at = strtoull(v, NULL, 10);
		else if (!strcmp(a, "--stall-ms")) o->stall_ms = strtoull(v, NULL, 10);
		else if (!strcmp(a, "--set")) {
			const char *eq = strchr(v, '=');
			const size_t used = strlen(o->settings);
			if (!eq || used + strlen(v) + 8 > sizeof o->settings) {
				fprintf(stderr, "--set wants <name>=<value>, not %s\n", v);
				return 0;
			}
			snprintf(o->settings + used, sizeof o->settings - used, "%s\"%.*s\":\"%s\"", used > 1 ? "," : "",
			         (int)(eq - v), v, eq + 1);
		}
		else if (!strcmp(a, "--save-state")) o->save_state = v;
		else if (!strcmp(a, "--state")) o->state = v;
		else if (!strcmp(a, "--ppm")) o->ppm = v;
		else if (!strcmp(a, "--ppm-at")) o->ppm_at = strtoull(v, NULL, 10);
		else if (!strcmp(a, "--dump-ram")) o->dump_ram = v;
		else if (!strcmp(a, "--digests")) o->digests = v;
		else if (!strcmp(a, "--key") || !strcmp(a, "--axis")) {
			unsigned long long from, count;
			int index, value = 1, n;
			const int axis = !strcmp(a, "--axis");
			n = axis ? sscanf(v, "%llu:%llu:%d:%d", &from, &count, &index, &value)
			         : sscanf(v, "%llu:%llu:%d", &from, &count, &index);
			if (o->events >= HARNESS_MAX_EVENTS || n != (axis ? 4 : 3)) {
				fprintf(stderr, "%s wants <frame>:<frames>:<index>%s, not %s\n", a, axis ? ":<value>" : "", v);
				return 0;
			}
			o->ev[o->events++] = (struct harness_event){ from, count, index, value, axis };
		} else if (!own || !own(a, v)) {
			fprintf(stderr, "no such option: %s\n", a);
			return 0;
		}
	}
	snprintf(o->settings_json, sizeof o->settings_json, "%s}", o->settings);
	if (o->save_state && !o->save_at) {
		fprintf(stderr, "--save-state wants --at <a frame of the run>\n");
		return 0;
	}
	return 1;
}

static uint64_t harness_hash(uint64_t h, const void *data, size_t bytes)
{
	const uint8_t *p = (const uint8_t *)data;
	for (size_t i = 0; i < bytes; i++)
		h = (h ^ p[i]) * 0x100000001b3ull;
	return h;
}
#define HARNESS_HASH_START 0xcbf29ce484222325ull

/* What a run has added up so far; a state file carries it, so that a run
 * carried on in another process ends with the sums of one that never stopped. */
struct harness_sums { uint64_t frame, input_frames, audio_samples, audio_hash, video_hash, audio_peak; };
#define HARNESS_STATE_MAGIC "86box-gate-state-1"

static uint64_t harness_picture_hash(const struct harness_core *c)
{
	return harness_hash(HARNESS_HASH_START, c->GetVideoBgra(),
	                    (size_t)c->GetVideoWidth() * (size_t)c->GetVideoHeight() * 4);
}

static void harness_line(const struct harness_core *c, const struct harness_sums *s, const char *what)
{
	const int w = c->GetVideoWidth(), h = c->GetVideoHeight();
	const int64_t ram = c->GetMemoryDomainSize(0);
	printf("%s frame=%" PRIu64 " machineMs=%" PRIu64 " cycles=%" PRIu64 " inputFrames=%" PRIu64
	       " audioPairs=%" PRIu64 " audioPeak=%" PRIu64 " audioHash=%016" PRIx64 " ramBytes=%" PRId64 " ramHash=%016" PRIx64
	       " video=%dx%d videoHash=%016" PRIx64 " videosHash=%016" PRIx64 "\n",
	       what, s->frame, c->GetMachineMs(), c->GetCpuCycles(), s->input_frames, s->audio_samples, s->audio_peak,
	       s->audio_hash,
	       ram, harness_hash(HARNESS_HASH_START, c->GetMemoryDomainPtr(0), (size_t)ram), w, h,
	       harness_picture_hash(c), s->video_hash);
	fflush(stdout);
}

/* The picture as a PPM: the simplest file a viewer opens. */
static void harness_ppm(const struct harness_core *c, const char *path)
{
	const int w = c->GetVideoWidth(), h = c->GetVideoHeight();
	const uint32_t *p = c->GetVideoBgra();
	FILE *f = fopen(path, "wb");
	if (!f) {
		fprintf(stderr, "cannot write %s\n", path);
		return;
	}
	fprintf(f, "P6\n%d %d\n255\n", w, h);
	for (int i = 0; i < w * h; i++) {
		const uint8_t rgb[3] = { (uint8_t)(p[i] >> 16), (uint8_t)(p[i] >> 8), (uint8_t)p[i] };
		fwrite(rgb, 1, 3, f);
	}
	fclose(f);
}

static void harness_input(const struct harness_core *c, const struct harness_opts *o, uint64_t f)
{
	/* levels, not events: every control a run names is told its state
	 * every frame, as the frontend tells them */
	for (int i = 0; i < o->events; i++) {
		const struct harness_event *e = &o->ev[i];
		int held = 0, value = 0;
		for (int j = 0; j < o->events; j++) {
			const struct harness_event *g = &o->ev[j];
			if (g->axis == e->axis && g->index == e->index && f >= g->from && f < g->from + g->count) {
				held = 1;
				value = g->value;
			}
		}
		if (e->axis) {
			if (c->SetAxis)
				c->SetAxis(e->index, held ? value : 0);
		} else if (c->SetButton) {
			c->SetButton(e->index, held);
		}
	}
}

/* Init has not been called. The process's exit code. */
static int harness_run(const struct harness_core *c, const struct harness_opts *o)
{
	if ((o->rerecord || o->save_state || o->state) && !c->save) {
		fprintf(stderr, "states are the sandbox's: this runner has none\n");
		return 2;
	}
	if (!c->Init()) {
		fprintf(stderr, "Init: %s\n", c->GetLoadError());
		return 1;
	}
	/* the machine as it stands after Init is what every state is against */
	if (c->seal && !c->seal())
		return 1;
	printf("machine=%s framesPerSecond=%d/%d\n", c->DebugMachine(), c->GetVsyncNumerator(), c->GetVsyncDenominator());

	struct harness_sums s = { 0, 0, 0, HARNESS_HASH_START, HARNESS_HASH_START, 0 };
	if (o->state) {
		FILE *f = fopen(o->state, "rb");
		char magic[sizeof HARNESS_STATE_MAGIC];
		uint64_t len = 0;
		if (!f || fread(magic, 1, sizeof magic, f) != sizeof magic || memcmp(magic, HARNESS_STATE_MAGIC, sizeof magic) ||
		    fread(&s, sizeof s, 1, f) != 1 || fread(&len, sizeof len, 1, f) != 1) {
			fprintf(stderr, "%s is not a state of these tests\n", o->state);
			return 2;
		}
		uint8_t *buf = (uint8_t *)malloc(len ? len : 1);
		if (!buf || fread(buf, 1, len, f) != len) {
			fprintf(stderr, "%s is cut short\n", o->state);
			return 2;
		}
		fclose(f);
		if (!c->load(buf, len))
			return 1;
		free(buf);
	}
	FILE *digests = o->digests ? fopen(o->digests, "w") : NULL;
	if (o->digests && !digests) {
		fprintf(stderr, "cannot write %s\n", o->digests);
		return 2;
	}

	while (s.frame < o->frames) {
		const uint64_t f = s.frame + 1;
		if (o->rerecord) {
			uint8_t *buf = NULL;
			size_t len = 0;
			if (!c->save(&buf, &len))
				return 1;
			/* the tests' control: once, half way, the state loaded is the
			 * one from the frame before - a state that is not this moment's
			 * must show in what the run ends with */
			static uint8_t *before;
			static size_t before_len;
			const char *stale = getenv("HARNESS_BREAK_STALE_STATE");
			if (stale && *stale && before && f == o->frames / 2) {
				if (!c->load(before, before_len))
					return 1;
			} else if (!c->load(buf, len)) {
				return 1;
			}
			free(before);
			before = buf;
			before_len = len;
		}
		if (o->stall_ms) {
			struct timespec ts = { (time_t)(o->stall_ms / 1000), (long)(o->stall_ms % 1000) * 1000000L };
			nanosleep(&ts, NULL);
		}
		harness_input(c, o, f);
		c->FrameAdvance(0);
		s.frame = f;
		s.input_frames += c->InputWasRead() ? 1 : 0;
		const int n = c->GetAudioSampleCount();
		uint64_t frame_peak = 0;
		if (n > 0) {
			s.audio_samples += (uint64_t)n;
			s.audio_hash = harness_hash(s.audio_hash, c->GetAudio(), (size_t)n * 4);
			/* the loudest sample, of the frame and of the run */
			const int16_t *a = c->GetAudio();
			for (int i = 0; i < n * 2; i++) {
				const uint64_t v = (uint64_t)(a[i] < 0 ? -(int)a[i] : a[i]);
				if (v > frame_peak)
					frame_peak = v;
			}
			if (frame_peak > s.audio_peak)
				s.audio_peak = frame_peak;
		}
		/* every frame's picture, added up: a picture that was wrong for one
		 * frame in the middle shows at the end */
		const uint64_t pic = harness_picture_hash(c);
		s.video_hash = harness_hash(s.video_hash, &pic, sizeof pic);
		if (digests)
			fprintf(digests, "%" PRIu64 " %" PRIu64 " %" PRIu64 " %016" PRIx64 " %" PRIu64 "\n", f, c->GetMachineMs(),
			        c->GetCpuCycles(), pic, frame_peak);
		if (o->every && f % o->every == 0 && f != o->frames)
			harness_line(c, &s, "at");
		if (o->ppm && o->ppm_at == f)
			harness_ppm(c, o->ppm);
		if (o->save_state && f == o->save_at) {
			uint8_t *buf = NULL;
			size_t len = 0;
			if (!c->save(&buf, &len))
				return 1;
			FILE *out = fopen(o->save_state, "wb");
			const uint64_t len64 = len;
			if (!out || fwrite(HARNESS_STATE_MAGIC, 1, sizeof HARNESS_STATE_MAGIC, out) != sizeof HARNESS_STATE_MAGIC ||
			    fwrite(&s, sizeof s, 1, out) != 1 || fwrite(&len64, sizeof len64, 1, out) != 1 ||
			    fwrite(buf, 1, len, out) != len || fclose(out) != 0) {
				fprintf(stderr, "cannot write %s\n", o->save_state);
				return 2;
			}
			printf("saved frame=%" PRIu64 " bytes=%zu\n", f, len);
			return 0;
		}
	}
	if (digests)
		fclose(digests);
	harness_line(c, &s, "end");
	if (o->ppm && !o->ppm_at)
		harness_ppm(c, o->ppm);
	if (o->dump_ram) {
		/* every memory domain, one after another: the motherboard's memory,
		 * then a memory card's (which starts where the motherboard's ends) */
		FILE *out = fopen(o->dump_ram, "wb");
		int ok = out != NULL;
		for (int d = 0; ok && d < 8 && c->GetMemoryDomainPtr(d) && c->GetMemoryDomainSize(d) > 0; d++)
			ok = fwrite(c->GetMemoryDomainPtr(d), 1, (size_t)c->GetMemoryDomainSize(d), out) ==
			     (size_t)c->GetMemoryDomainSize(d);
		if (!ok || fclose(out) != 0) {
			fprintf(stderr, "cannot write %s\n", o->dump_ram);
			return 2;
		}
	}
	return 0;
}

#endif
