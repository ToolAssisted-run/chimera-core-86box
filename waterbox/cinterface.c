/* cinterface.c - the guest interface of the 86Box core: what Chimera calls
 * (Init, FrameAdvance, the picture, the sound, the memory) and the
 * configuration 86Box is started with, composed from the project's
 * settings.
 *
 * Built into the sandboxed core and into the native reference alike; the
 * native runner (run-native.c) calls these functions directly.
 */
#define _GNU_SOURCE
#include <inttypes.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <emulibc.h>
#include <waterbox_settings.h>
#include <waterbox_slots.h>

#include <86box/86box.h>
#include <86box/device.h>
#include <86box/timer.h>
#include <86box/machine.h>
#include <86box/mem.h>
#include <86box/plat.h>
#include <86box/video.h>
#include <86box/sound.h>
#include <86box/fdd.h>
#include <86box/keyboard.h>
#include <86box/mouse.h>
#include <86box/gameport.h>
#include "cpu.h"

#include "chimera.h"

/* A text a person reads is a key of languages/en.json; its arguments
 * follow, each after a TEXT_ARG (chimera docs/translations.md). */
#define TEXT_ARG "\x1f"

extern int  pc_init(int argc, char *argv[]);
extern int  pc_init_modules(void);
extern void pc_reset_hard_init(void);
extern void pc_run(void);
extern int  machine;

/* ---------------------------------------------------------- the state */

uint64_t chimera_ms;
int chimera_powered_off;

static char g_loadError[1024];
static uint64_t g_frames;
static int g_fpsNum = 100, g_fpsDen = 1;
static uint64_t g_msAcc;

/* the configuration 86Box reads (CHIMERA_CFG_NAME) */
static char g_cfg[16384];
static size_t g_cfgLen;

/* --------------------------------------------------- random numbers
 *
 * 86Box's C files call rand() and srand() under these names. musl's and
 * glibc's generators differ, so the native reference and the sandbox would
 * not be one machine with the C library's; this is the same in both, and its
 * state is ordinary memory, so a state carries it. */
static uint64_t g_rand = 1;
void chimera_srand(unsigned seed) { g_rand = seed; }
int chimera_rand(void)
{
	g_rand = g_rand * 6364136223846793005ull + 1442695040888963407ull;
	return (int)((g_rand >> 33) & 0x7fffffff);
}

/* ------------------------------------------------- the configuration */

static void cfg_add(const char *fmt, ...)
{
	va_list ap;
	int n;
	va_start(ap, fmt);
	n = vsnprintf(g_cfg + g_cfgLen, sizeof g_cfg - g_cfgLen, fmt, ap);
	va_end(ap);
	if (n > 0 && (size_t)n < sizeof g_cfg - g_cfgLen)
		g_cfgLen += (size_t)n;
}

FILE *chimera_cfg_open(void) { return fmemopen(g_cfg, g_cfgLen, "rb"); }

/* jsmn hands back a string's raw text, escapes and all */
static void json_unescape(char *s)
{
	char *r = s, *w = s;
	while (*r) {
		if (*r != '\\') { *w++ = *r++; continue; }
		r++;
		switch (*r) {
		case 0: *w = 0; return;
		case 'n': *w++ = '\n'; r++; break;
		case 't': *w++ = '\t'; r++; break;
		default: *w++ = *r++; break;
		}
	}
	*w = 0;
}

static const char *setting_str(const char *key, const char *dflt, char *out, int outsz)
{
	if (wbx_setting_str(key, out, outsz) < 0)
		snprintf(out, (size_t)outsz, "%s", dflt);
	else
		json_unescape(out);
	return out;
}

/* A value of an enum is shown as "internal - Name"; the id is what is
 * before the first " - ". */
static const char *setting_id(const char *key, const char *dflt, char *out, int outsz)
{
	char raw[256];
	char *dash;
	setting_str(key, dflt, raw, sizeof raw);
	dash = strstr(raw, " - ");
	if (dash)
		*dash = 0;
	snprintf(out, (size_t)outsz, "%s", raw);
	return out;
}

/* Missing files, as plat_fopen saw them while 86Box looked for a machine's
 * or a card's ROMs: the load error names them. */
static char g_missing[2048];
static int g_watchMissing;

void chimera_file_opened(const char *name, int found)
{
	/* for whoever is finding out which files a machine wants */
	if (getenv("CHIMERA_86BOX_TRACE_FILES"))
		fprintf(stderr, "86box: %s %s\n", found ? "opened" : "no such file", name);
	if (!g_watchMissing || found || strstr(g_missing, name))
		return;
	if (strlen(g_missing) + strlen(name) + 3 < sizeof g_missing) {
		if (g_missing[0])
			strcat(g_missing, ", ");
		strcat(g_missing, name);
	}
}

static int compose_cfg(void)
{
	char machineName[64], bios[64], cpuFamily[64], fpu[32], video[64], sound[64];
	char fddA[32], fddB[32], mouseName[32], joystickName[32], hdc[64], fdc[64];
	char slotA[256], slotB[256];
	long mem, cpuSpeed;
	int m;

	setting_id("machine", "xi8088", machineName, sizeof machineName);
	m = machine_get_machine_from_internal_name(machineName);
	if (m < 0) {
		snprintf(g_loadError, sizeof g_loadError, "error.no_such_machine" TEXT_ARG "%s", machineName);
		return 0;
	}
	setting_id("bios", "", bios, sizeof bios);
	setting_id("cpuFamily", "", cpuFamily, sizeof cpuFamily);
	cpuSpeed = wbx_setting_long("cpuSpeed", 0);
	setting_id("fpu", "none", fpu, sizeof fpu);
	mem = wbx_setting_long("memoryKB", 0);
	setting_id("video", "internal", video, sizeof video);
	setting_id("sound", "none", sound, sizeof sound);
	setting_id("floppyA", "525_2dd", fddA, sizeof fddA);
	setting_id("floppyB", "none", fddB, sizeof fddB);
	setting_id("hardDiskController", "none", hdc, sizeof hdc);
	setting_id("floppyController", "internal", fdc, sizeof fdc);
	setting_id("mouse", "none", mouseName, sizeof mouseName);
	setting_id("joystick", "none", joystickName, sizeof joystickName);

	g_cfgLen = 0;
	cfg_add("[General]\n");
	/* one millisecond of machine time a call of pc_run, as upstream runs */
	cfg_add("force_10ms = 0\n");
	cfg_add("fdd_sounds_enabled = 0\n");
	cfg_add("confirm_reset = 0\nconfirm_exit = 0\nconfirm_save = 0\n");

	cfg_add("\n[Machine]\n");
	cfg_add("machine = %s\n", machineName);
	if (cpuFamily[0]) {
		cfg_add("cpu_family = %s\n", cpuFamily);
		cfg_add("cpu_speed = %ld\n", cpuSpeed);
		cfg_add("cpu_multi = %s\n", "0");
	}
	cfg_add("fpu_type = %s\n", fpu);
	if (mem > 0)
		cfg_add("mem_size = %ld\n", mem);
	cfg_add("cpu_use_dynarec = %d\n", wbx_setting_bool("dynarec", 0) ? 1 : 0);
	cfg_add("fpu_softfloat = %d\n", wbx_setting_bool("softfloat", 1) ? 1 : 0);
	/* the RTC is set at power-on from the project's date (patch 0001) */
	cfg_add("time_sync = utc\n");

	cfg_add("\n[Video]\ngfxcard = %s\n", video);

	cfg_add("\n[Sound]\nsndcard = %s\n", sound);
	cfg_add("sound_type = int16\n");
	cfg_add("fm_driver = nuked\n");

	cfg_add("\n[Input devices]\nmouse_type = %s\njoystick_type = %s\n", mouseName, joystickName);

	cfg_add("\n[Storage controllers]\nfdc = %s\nhdc = %s\n", fdc, hdc);

	cfg_add("\n[Floppy and CD-ROM drives]\n");
	cfg_add("fdd_01_type = %s\nfdd_02_type = %s\n", fddA, fddB);
	if (wbx_slot_first("floppy_a", slotA, sizeof slotA) && slotA[0])
		cfg_add("fdd_01_fn = wp://%s\nfdd_01_writeprot = 1\n", slotA);
	if (wbx_slot_first("floppy_b", slotB, sizeof slotB) && slotB[0])
		cfg_add("fdd_02_fn = wp://%s\nfdd_02_writeprot = 1\n", slotB);

	if (bios[0]) {
		const device_t *d = machine_get_device(m);
		if (!d || !d->config) {
			snprintf(g_loadError, sizeof g_loadError, "error.machine_has_one_bios" TEXT_ARG "%s", machineName);
			return 0;
		}
		cfg_add("\n[%s]\nbios = %s\n", d->name, bios);
	}
	return 1;
}

/* ----------------------------------------------------------- the picture */

#define VIDEO_MAX_W 2048
#define VIDEO_MAX_H 2048
static uint32_t *g_frame;
static int g_width = 640, g_height = 480;
static uint64_t g_blits;

static void chimera_blit(int x, int y, int w, int h, int monitor_index)
{
	if (monitor_index == 0 && w > 0 && h > 0 && buffer32) {
		if (w > VIDEO_MAX_W)
			w = VIDEO_MAX_W;
		if (h > VIDEO_MAX_H)
			h = VIDEO_MAX_H;
		for (int row = 0; row < h; row++) {
			if (y + row < 0 || y + row >= buffer32->h)
				continue;
			video_copy(g_frame + (size_t)row * (size_t)w, &buffer32->line[y + row][x], (size_t)w * 4);
		}
		g_width = w;
		g_height = h;
		g_blits++;
	}
	video_blit_complete_monitor(monitor_index);
}

/* ------------------------------------------------------------ drives */

void chimera_drive_activity(int tag, int active) { (void)tag; (void)active; }

/* ----------------------------------------------------------- the ABI */

ECL_EXPORT const char *GetLoadError(void) { return g_loadError; }

/* the configuration 86Box was started with, for the tests */
ECL_EXPORT const char *GetComposedConfig(void) { return g_cfg; }

/* the clock the machine is switched on at, seconds since 1970 (UTC) */
static int64_t g_clockStart;
int64_t plat_machine_clock_start(void)
{
	/* The tests' negative control for virtual time, in the native build
	 * only (the sandbox has no environment and no clock): the date the
	 * host says, as upstream reads it. */
	if (getenv("CHIMERA_86BOX_HOST_CLOCK"))
		return (int64_t)time(NULL);
	return g_clockStart;
}

ECL_EXPORT int Init(void)
{
	/* the machine's folder is where 86Box starts (plat_getcwd); the
	 * global configuration it would keep beside its program is not there */
	char *argv[] = { "86Box", "-C", CHIMERA_CFG_NAME, "-O", CHIMERA_VM_PATH "86box_global.cfg", NULL };

	g_loadError[0] = 0;
	g_frame = (uint32_t *)calloc((size_t)VIDEO_MAX_W * VIDEO_MAX_H, 4);
	if (!g_frame) {
		snprintf(g_loadError, sizeof g_loadError, "error.no_frame_buffer");
		return 0;
	}
	g_clockStart = wbx_setting_long("clockStart", 946684800);

	if (!compose_cfg())
		return 0;

	if (!pc_init(5, argv)) {
		snprintf(g_loadError, sizeof g_loadError, "error.start_failed");
		return 0;
	}

	/* the machine's ROMs: refused by name rather than replaced by another
	 * machine, which is what 86Box's own interface does */
	g_watchMissing = 1;
	g_missing[0] = 0;
	if (!machine_available(machine)) {
		g_watchMissing = 0;
		snprintf(g_loadError, sizeof g_loadError, "error.machine_roms_missing" TEXT_ARG "%s" TEXT_ARG "%s",
		         machine_getname(machine), g_missing);
		return 0;
	}
	g_missing[0] = 0;
	if (!video_card_available(gfxcard[0])) {
		g_watchMissing = 0;
		snprintf(g_loadError, sizeof g_loadError, "error.video_roms_missing" TEXT_ARG "%s" TEXT_ARG "%s",
		         video_get_internal_name(gfxcard[0]), g_missing);
		return 0;
	}
	g_watchMissing = 0;

	video_setblit(chimera_blit);
	pc_init_modules();
	pc_reset_hard_init();
	plat_pause(0);
	/* the mice report only while 86Box's window holds the pointer; the
	 * core's machine always does: its mouse is the movie's */
	mouse_capture = 1;

	if (chimera_thread_refused[0]) {
		snprintf(g_loadError, sizeof g_loadError, "error.device_needs_thread" TEXT_ARG "%s", chimera_thread_refused);
		return 0;
	}

	{
		long num = wbx_setting_long("framesPerSecond", 100);
		if (num <= 0 || num > 1000)
			num = 100;
		g_fpsNum = (int)num;
		g_fpsDen = 1;
	}
	return 1;
}

ECL_EXPORT void FrameAdvance(uint64_t packed)
{
	chimera_set_packed(packed);
	chimera_apply_input(g_width, g_height);
	chimera_input_read = 0;
	chimera_audio_frame_start();
	/* machine time in whole milliseconds, one pc_run each; a frame rate that
	 * does not divide a second runs the rest in the frames after */
	g_msAcc += (uint64_t)1000 * (uint64_t)g_fpsDen;
	while (g_msAcc >= (uint64_t)g_fpsNum) {
		g_msAcc -= (uint64_t)g_fpsNum;
		pc_run();
		chimera_ms++;
	}
	g_frames++;
	/* the relative axes are this frame's movement: spent */
	chimera_set_axis(CHIMERA_AXIS_MOUSE_X, 0);
	chimera_set_axis(CHIMERA_AXIS_MOUSE_Y, 0);
}

ECL_EXPORT uint32_t *GetVideoBgra(void) { return g_frame; }
ECL_EXPORT int GetVideoWidth(void) { return g_width; }
ECL_EXPORT int GetVideoHeight(void) { return g_height; }
ECL_EXPORT int GetVsyncNumerator(void) { return g_fpsNum; }
ECL_EXPORT int GetVsyncDenominator(void) { return g_fpsDen; }

/* the frame's sound: chimera-audio.c */
ECL_EXPORT int16_t *GetAudio(void) { return chimera_audio_buffer(); }
ECL_EXPORT int GetAudioSampleCount(void) { return chimera_audio_pairs(); }

ECL_EXPORT int InputWasRead(void) { return chimera_input_read; }

/* for the tests: how much machine the run has been */
ECL_EXPORT uint64_t GetMachineMs(void) { return chimera_ms; }
ECL_EXPORT uint64_t GetCpuCycles(void) { return tsc; }
ECL_EXPORT uint64_t GetBlitCount(void) { return g_blits; }
ECL_EXPORT const char *DebugMachine(void) { return machine_get_internal_name(); }

ECL_EXPORT int GetMemoryDomainCount(void) { return 1; }
ECL_EXPORT const char *GetMemoryDomainName(int i) { return i == 0 ? "System RAM" : NULL; }
ECL_EXPORT uint8_t *GetMemoryDomainPtr(int i) { return i == 0 ? ram : NULL; }
ECL_EXPORT int64_t GetMemoryDomainSize(int i) { return i == 0 ? (int64_t)mem_size * 1024 : 0; }
ECL_EXPORT int GetMemoryDomainWritable(int i) { return i == 0; }

/* The controls: chimera-input.c. */
ECL_EXPORT void SetButton(int32_t index, int32_t state) { chimera_set_button(index, state); }
ECL_EXPORT void SetAxis(int32_t index, int32_t value) { chimera_set_axis(index, value); }
