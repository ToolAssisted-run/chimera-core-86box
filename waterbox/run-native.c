#define _GNU_SOURCE
/* The native reference of the core: the same exports the sandbox has
 * (cinterface.c and chimera-plat.c, compiled for the host), called
 * directly, a frame at a time, by the harness the sandboxed runner uses
 * (gate-harness.h).
 *
 *   run-native <work directory, which must not exist> [--roms DIR]
 *              [--file SLOT=PATH]... [harness options]
 *
 * --roms DIR        every file in DIR is firmware, handed over under its own
 *                   name: the firmware's id ("machines_xi8088_bios-xi8088.bin")
 * --file SLOT=PATH  a file of the project, in a slot of file_slots.json
 *                   (floppy_a, floppy_b, hdd, cdrom), in the order given
 *
 * Natively there are no states. The core opens its files where it is
 * started, as it finds them mounted in the sandbox: the directory is this
 * run's own, and each file is copied into it under its name.
 */
#include <dirent.h>
#include <limits.h>
#include <sys/stat.h>
#include <unistd.h>

#include "gate-harness.h"

int Init(void);
const char *GetLoadError(void);
void FrameAdvance(uint64_t);
void SetButton(int32_t, int32_t);
void SetAxis(int32_t, int32_t);
int InputWasRead(void);
int16_t *GetAudio(void);
int GetAudioSampleCount(void);
uint32_t *GetVideoBgra(void);
int GetVideoWidth(void);
int GetVideoHeight(void);
int GetVsyncNumerator(void);
int GetVsyncDenominator(void);
uint8_t *GetMemoryDomainPtr(int);
int64_t GetMemoryDomainSize(int);
const char *DebugMachine(void);
uint64_t GetMachineMs(void);
uint64_t GetCpuCycles(void);
const uint8_t *DebugCmos(void);
int DebugCmosSize(void);

static int write_file(const char *name, const char *text)
{
	FILE *f = fopen(name, "wb");
	if (!f)
		return 0;
	fputs(text, f);
	return fclose(f) == 0;
}

static int copy_file(const char *from, const char *to)
{
	FILE *in = fopen(from, "rb"), *out = in ? fopen(to, "wb") : NULL;
	if (!out) {
		if (in)
			fclose(in);
		return 0;
	}
	char buf[65536];
	size_t n;
	while ((n = fread(buf, 1, sizeof buf, in)) > 0)
		fwrite(buf, 1, n, out);
	fclose(in);
	return fclose(out) == 0;
}

/* a path given relative to where the runner was started still names the
 * same file after the runner has moved into its work directory */
static const char *absolute(const char *path, char *out)
{
	if (!path || path[0] == '/')
		return path;
	char cwd[PATH_MAX];
	if (!getcwd(cwd, sizeof cwd))
		return path;
	snprintf(out, PATH_MAX, "%s/%s", cwd, path);
	return out;
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
	if (argc < 2) {
		fprintf(stderr, "usage: run-native <work directory> [options]\n");
		return 2;
	}
	struct harness_opts o;
	if (!harness_parse(argc, argv, 2, &o, own_option))
		return 2;
	static char roms[PATH_MAX], ppm[PATH_MAX], ram[PATH_MAX], dig[PATH_MAX], files[MAX_FILES][PATH_MAX];
	if (g_roms && !realpath(g_roms, roms)) {
		fprintf(stderr, "run-native: no such folder of ROMs: %s\n", g_roms);
		return 2;
	}
	for (int i = 0; i < g_files; i++)
		if (!realpath(g_path[i], files[i])) {
			fprintf(stderr, "run-native: no such file: %s\n", g_path[i]);
			return 2;
		}
	o.ppm = absolute(o.ppm, ppm);
	o.dump_ram = absolute(o.dump_ram, ram);
	o.digests = absolute(o.digests, dig);
	if (mkdir(argv[1], 0777) != 0 || chdir(argv[1]) != 0) {
		fprintf(stderr, "run-native: %s must be a directory that can be made and is not there yet\n", argv[1]);
		return 2;
	}
	if (g_roms) {
		DIR *d = opendir(roms);
		struct dirent *e;
		while (d && (e = readdir(d)) != NULL) {
			char from[PATH_MAX * 2];
			if (e->d_name[0] == '.')
				continue;
			snprintf(from, sizeof from, "%s/%s", roms, e->d_name);
			copy_file(from, e->d_name);
		}
		if (d)
			closedir(d);
	}
	/* the slot map, as a project's: slot id -> names in order */
	char slots[8192] = "{";
	for (int i = 0; i < g_files; i++) {
		const char *base = strrchr(files[i], '/') + 1;
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
			const char *b = strrchr(files[j], '/') + 1;
			used = strlen(slots);
			snprintf(slots + used, sizeof slots - used, "%s\"%s\"", j == i ? "" : ",", b);
		}
		strcat(slots, "]");
		if (!copy_file(files[i], base)) {
			fprintf(stderr, "run-native: cannot copy %s\n", files[i]);
			return 2;
		}
	}
	for (int i = 0; i < g_files; i++)
		copy_file(files[i], strrchr(files[i], '/') + 1);
	strcat(slots, "}");
	if (!write_file("settings", o.settings_json) || !write_file("slots", slots)) {
		fprintf(stderr, "run-native: cannot write into %s\n", argv[1]);
		return 2;
	}
	const struct harness_core core = {
		Init, GetLoadError, FrameAdvance, SetButton, SetAxis, InputWasRead, GetAudio, GetAudioSampleCount,
		GetVideoBgra, GetVideoWidth, GetVideoHeight, GetVsyncNumerator, GetVsyncDenominator,
		GetMemoryDomainPtr, GetMemoryDomainSize, DebugMachine, GetMachineMs, GetCpuCycles, DebugCmos, DebugCmosSize,
		NULL, NULL, NULL,
	};
	const int result = harness_run(&core, &o);
	fflush(stdout);
	fflush(stderr);
	return result;
}
