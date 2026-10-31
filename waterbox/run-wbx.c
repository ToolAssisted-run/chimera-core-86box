#define _GNU_SOURCE
/* Runs the core (core.wbx) in the sandbox the way the frontend does: the
 * firmware and the project's files mounted under their names, "slots" and
 * "settings" beside them, Init, the machine sealed, and then a frame at a
 * time by the harness the native runner uses (gate-harness.h).
 *
 *   run-wbx <core.wbx> <waterbox.config> [--roms DIR] [--file SLOT=PATH]...
 *           [harness options]
 *
 * The memory layout is read from the waterbox.config given, so the runner
 * cannot fall behind the package (docs/gates.md, C). The options are
 * run-native's; the states are miniBox's. (After chimera-core-fuse's.)
 */
#include <dirent.h>
#include <limits.h>

#include "minibox.h"

#include "gate-harness.h"

static mb_host *g_host;

typedef struct { FILE *f; } freader;
static intptr_t file_read(uintptr_t ud, uint8_t *data, uintptr_t size)
{
	return (intptr_t)fread(data, 1, size, ((freader *)ud)->f);
}

typedef struct { uint8_t *b; size_t len, cap, pos; } membuf;
static int32_t mem_write(uintptr_t ud, const uint8_t *d, uintptr_t n)
{
	membuf *m = (membuf *)ud;
	if (m->len + n > m->cap) {
		size_t cap = m->cap ? m->cap * 2 : ((size_t)1 << 20);
		while (cap < m->len + n)
			cap *= 2;
		uint8_t *b = (uint8_t *)realloc(m->b, cap);
		if (!b)
			return -1;
		m->b = b;
		m->cap = cap;
	}
	memcpy(m->b + m->len, d, n);
	m->len += n;
	return 0;
}
static intptr_t mem_read(uintptr_t ud, uint8_t *d, uintptr_t n)
{
	membuf *m = (membuf *)ud;
	size_t left = m->len - m->pos;
	if (n > left)
		n = left;
	memcpy(d, m->b + m->pos, n);
	m->pos += n;
	return (intptr_t)n;
}

/* the machine as Init left it is what every state is against */
static int do_seal(void)
{
	mb_return r;
	wbx_deactivate_host(g_host, &r);
	wbx_seal(g_host, &r);
	if (r.error_message[0]) {
		fprintf(stderr, "run-wbx: seal: %s\n", (const char *)r.error_message);
		return 0;
	}
	wbx_activate_host(g_host, &r);
	return 1;
}
static int do_save(uint8_t **buf, size_t *len)
{
	membuf m = { 0 };
	mb_return r;
	wbx_save_state(g_host, mem_write, (uintptr_t)&m, &r);
	if (r.error_message[0]) {
		fprintf(stderr, "run-wbx: save: %s\n", (const char *)r.error_message);
		free(m.b);
		return 0;
	}
	*buf = m.b;
	*len = m.len;
	return 1;
}
static int do_load(const uint8_t *buf, size_t len)
{
	membuf m = { (uint8_t *)buf, len, len, 0 };
	mb_return r;
	wbx_load_state(g_host, mem_read, (uintptr_t)&m, &r);
	if (r.error_message[0]) {
		fprintf(stderr, "run-wbx: load: %s\n", (const char *)r.error_message);
		return 0;
	}
	return 1;
}

static uintptr_t proc(const char *name)
{
	mb_return r;
	wbx_get_proc_addr(g_host, name, &r);
	if (r.error_message[0] || !r.data) {
		fprintf(stderr, "run-wbx: the core has no %s %s\n", name, (const char *)r.error_message);
		exit(2);
	}
	return r.data;
}

/* text mounted as a file; the buffers live as long as the process */
static membuf g_texts[4];
static int g_ntexts;
static void mount_text(const char *name, const char *text)
{
	membuf *m = &g_texts[g_ntexts++];
	m->b = (uint8_t *)strdup(text);
	m->len = m->cap = strlen(text);
	m->pos = 0;
	mb_return r;
	wbx_mount_file(g_host, name, mem_read, (uintptr_t)m, false, &r);
	if (r.error_message[0]) {
		fprintf(stderr, "run-wbx: %s: %s\n", name, (const char *)r.error_message);
		exit(2);
	}
}

static void mount_path(const char *name, const char *path)
{
	mb_return r;
	/* names of the mount's own: the directory entry is reused */
	wbx_mount_file_path(g_host, strdup(name), strdup(path), &r);
	if (r.error_message[0]) {
		fprintf(stderr, "run-wbx: %s: %s\n", path, (const char *)r.error_message);
		exit(2);
	}
}

/* "memoryLayoutMiB": [sbrk, sealed, invisible, plain, mmap] */
static int read_layout(const char *config, mb_memory_layout_template *l)
{
	FILE *f = fopen(config, "rb");
	static char text[1 << 20];
	size_t n;
	unsigned long long v[5];
	if (!f)
		return 0;
	n = fread(text, 1, sizeof text - 1, f);
	fclose(f);
	text[n] = 0;
	const char *p = strstr(text, "\"memoryLayoutMiB\"");
	if (!p || !(p = strchr(p, '[')) ||
	    sscanf(p, "[ %llu , %llu , %llu , %llu , %llu", &v[0], &v[1], &v[2], &v[3], &v[4]) != 5)
		return 0;
	l->sbrk_size = v[0] << 20;
	l->sealed_size = v[1] << 20;
	l->invis_size = v[2] << 20;
	l->plain_size = v[3] << 20;
	l->mmap_size = v[4] << 20;
	return 1;
}

static const char *g_roms;
#define MAX_FILES 32
static const char *g_slot[MAX_FILES], *g_path[MAX_FILES];
static int g_files;

static int own_option(const char *name, const char *value)
{
	if (!strcmp(name, "--roms")) {
		g_roms = value;
		return 1;
	}
	if (!strcmp(name, "--file")) {
		const char *eq = strchr(value, '=');
		if (!eq || g_files >= MAX_FILES)
			return 0;
		g_slot[g_files] = strndup(value, (size_t)(eq - value));
		g_path[g_files] = eq + 1;
		g_files++;
		return 1;
	}
	return 0;
}

int main(int argc, char **argv)
{
	if (argc < 3) {
		fprintf(stderr, "usage: run-wbx <core.wbx> <waterbox.config> [options]\n");
		return 2;
	}
	struct harness_opts o;
	if (!harness_parse(argc, argv, 3, &o, own_option))
		return 2;
	mb_memory_layout_template layout = { 0 };
	if (!read_layout(argv[2], &layout)) {
		fprintf(stderr, "run-wbx: no memoryLayoutMiB in %s\n", argv[2]);
		return 2;
	}
	FILE *f = fopen(argv[1], "rb");
	if (!f) {
		fprintf(stderr, "run-wbx: cannot open %s\n", argv[1]);
		return 2;
	}
	freader fr = { f };
	mb_return r;
	wbx_create_host(&layout, "core.wbx", file_read, (uintptr_t)&fr, &r);
	fclose(f);
	if (r.error_message[0]) {
		fprintf(stderr, "run-wbx: create_host: %s\n", (const char *)r.error_message);
		return 2;
	}
	g_host = (mb_host *)r.data;

	/* the firmware, each file under its own name: the firmware's id */
	if (g_roms) {
		DIR *d = opendir(g_roms);
		struct dirent *e;
		if (!d) {
			fprintf(stderr, "run-wbx: no such folder of ROMs: %s\n", g_roms);
			return 2;
		}
		while ((e = readdir(d)) != NULL) {
			char from[PATH_MAX * 2];
			if (e->d_name[0] == '.')
				continue;
			snprintf(from, sizeof from, "%s/%s", g_roms, e->d_name);
			mount_path(e->d_name, from);
		}
		closedir(d);
	}
	/* the project's files, and the slot map: slot id -> names in order */
	static char slots[8192] = "{";
	for (int i = 0; i < g_files; i++) {
		int first = 1;
		for (int j = 0; j < i; j++)
			if (!strcmp(g_slot[j], g_slot[i]))
				first = 0;
		if (!first)
			continue;
		size_t used = strlen(slots);
		snprintf(slots + used, sizeof slots - used, "%s\"%s\":[", used > 1 ? "," : "", g_slot[i]);
		for (int j = i; j < g_files; j++) {
			if (strcmp(g_slot[j], g_slot[i]))
				continue;
			const char *b = strrchr(g_path[j], '/');
			b = b ? b + 1 : g_path[j];
			used = strlen(slots);
			snprintf(slots + used, sizeof slots - used, "%s\"%s\"", j == i ? "" : ",", b);
		}
		strcat(slots, "]");
	}
	strcat(slots, "}");
	for (int i = 0; i < g_files; i++) {
		const char *b = strrchr(g_path[i], '/');
		mount_path(b ? b + 1 : g_path[i], g_path[i]);
	}
	mount_text("slots", slots);
	mount_text("settings", o.settings_json);

	wbx_activate_host(g_host, &r);
	if (r.error_message[0]) {
		fprintf(stderr, "run-wbx: activate: %s\n", (const char *)r.error_message);
		return 2;
	}

	/* on Linux the guest's calling convention is the host's: the exports are
	 * called as plain functions */
	const struct harness_core core = {
		(int (*)(void))proc("Init"),
		(const char *(*)(void))proc("GetLoadError"),
		(void (*)(uint64_t))proc("FrameAdvance"),
		(void (*)(int32_t, int32_t))proc("SetButton"),
		(void (*)(int32_t, int32_t))proc("SetAxis"),
		(int (*)(void))proc("InputWasRead"),
		(int16_t *(*)(void))proc("GetAudio"),
		(int (*)(void))proc("GetAudioSampleCount"),
		(uint32_t *(*)(void))proc("GetVideoBgra"),
		(int (*)(void))proc("GetVideoWidth"),
		(int (*)(void))proc("GetVideoHeight"),
		(int (*)(void))proc("GetVsyncNumerator"),
		(int (*)(void))proc("GetVsyncDenominator"),
		(uint8_t *(*)(int))proc("GetMemoryDomainPtr"),
		(int64_t (*)(int))proc("GetMemoryDomainSize"),
		(const char *(*)(void))proc("DebugMachine"),
		(uint64_t (*)(void))proc("GetMachineMs"),
		(uint64_t (*)(void))proc("GetCpuCycles"),
		do_seal, do_save, do_load,
	};
	const int result = harness_run(&core, &o);
	fflush(stdout);
	fflush(stderr);
	return result;
}
