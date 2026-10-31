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
#include <86box/hdc.h>
#include <86box/gameport.h>
#include "cpu.h"
#include <86box/mouse.h>

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

/* ROM files 86Box read and did not find while the machine was built
 * (g_missing), and those it only asked about, while it was asked whether a
 * machine or a card is there (g_asked): the load error names them. Asking is
 * not reading: a machine asks about every file of every BIOS it could have. */
static char g_missing[2048], g_asked[2048];
static int g_watchMissing;

void chimera_file_asked(const char *name, int rom, int found)
{
	if (!g_watchMissing || !rom || found || strstr(g_asked, name))
		return;
	if (strlen(g_asked) + strlen(name) + 3 < sizeof g_asked) {
		if (g_asked[0])
			strcat(g_asked, ", ");
		strcat(g_asked, name);
	}
}

static int g_needsCharRom = 1;

void chimera_file_opened(const char *name, int rom, int found)
{
	/* for whoever is finding out which files a machine wants */
	if (getenv("CHIMERA_86BOX_TRACE_FILES"))
		fprintf(stderr, "86box: %s %s\n", found ? "opened" : "no such file", name);
	if (!g_watchMissing || !rom || found || strstr(g_missing, name))
		return;
	/* 86Box reads IBM's character ROM whenever the video is reset, for
	 * every card; only CGA, MDA and Hercules draw with it (EGA and VGA have
	 * their own in their BIOS). Missing, it is not needed for those. */
	if (!g_needsCharRom && !strcmp(name, "video_mda_mda.rom"))
		return;
	if (strlen(g_missing) + strlen(name) + 3 < sizeof g_missing) {
		if (g_missing[0])
			strcat(g_missing, ", ");
		strcat(g_missing, name);
	}
}

/* What a machine will take, for a refusal that says what to choose instead
 * - a list is worth more than "invalid". */
static void append(char *out, size_t outsz, const char *item)
{
	if (strlen(out) + strlen(item) + 3 >= outsz)
		return;
	if (out[0])
		strcat(out, ", ");
	strcat(out, item);
}

/* BIOS choices 86Box offers that the core does not (tools/gen-config.py,
 * BIOS_LEFT_OUT): the IBM XT's "(Alt)" BIOS, whose second chip's file is not
 * in the ROM set of 86Box, v6.0 */
static int bios_left_out(const char *id)
{
	return !strcmp(id, "ibm5160_1501512_6359116");
}

/* the machine's BIOS choices (a device config of type CONFIG_BIOS) */
static const device_config_t *bios_config(int m)
{
	const device_t *d = machine_get_device(m);
	for (const device_config_t *c = d ? d->config : NULL; c && c->type != CONFIG_END; c++)
		if (c->type == CONFIG_BIOS)
			return c;
	return NULL;
}

/* "family/speed" against the machine: 1 when it takes that CPU */
static int cpu_taken(int m, const char *family, long speed, char *choices, size_t chsz)
{
	int found = 0;
	choices[0] = 0;
	for (int f = 0; cpu_families[f].package; f++) {
		const cpu_family_t *fam = &cpu_families[f];
		if (!cpu_family_is_eligible(fam, m))
			continue;
		for (int c = 0; fam->cpus[c].cpu_type; c++) {
			char item[96];
			if (!cpu_is_eligible(fam, c, m))
				continue;
			snprintf(item, sizeof item, "%s/%u", fam->internal_name, fam->cpus[c].rspeed);
			append(choices, chsz, item);
			if (!strcmp(fam->internal_name, family) && (long)fam->cpus[c].rspeed == speed)
				found = 1;
		}
	}
	return found;
}

/* a device of a table (a video card, a sound card, a mouse) by its
 * internal name, and whether the machine can have it */
static int device_taken(int m, const char *want, const device_t *(*get)(int), const char *(*name)(int),
                        char *choices, size_t chsz)
{
	int found = 0;
	choices[0] = 0;
	for (int c = 0; c < 4096; c++) {
		const device_t *d = get(c);
		if (!d && c > 1)
			break;
		if (!name(c)[0] || (d && !device_is_valid(d, m)))
			continue;
		append(choices, chsz, name(c));
		if (!strcmp(name(c), want))
			found = 1;
	}
	return found;
}
static const device_t *vid_dev(int c) { return video_card_getdevice(c); }
static const char *vid_name(int c) { return video_get_internal_name(c); }
static const device_t *snd_dev(int c) { return sound_card_getdevice(c); }
static const char *snd_name(int c) { return sound_card_get_internal_name(c); }
static const device_t *mouse_dev(int c) { return mouse_get_device(c); }
static const char *mouse_name(int c) { return mouse_get_internal_name(c); }

static const device_t *hdc_dev(int c) { return hdc_get_device(c); }
static const char *hdc_name(int c) { return hdc_get_internal_name(c); }

/* A raw hard disk image's geometry (sectors a track, heads, cylinders),
 * from its size: the first of the usual shapes that divides it exactly, so
 * an image made for a machine reads back as that machine made it; else 63
 * sectors and 16 heads, with the cylinders that fit. */
static void hdd_geometry(int64_t size, unsigned *spt, unsigned *hpc, unsigned *cyl)
{
	static const unsigned shapes[][2] = { { 17, 4 }, { 17, 5 }, { 17, 6 }, { 17, 8 }, { 26, 4 }, { 63, 16 },
	                                      { 63, 15 }, { 32, 16 }, { 63, 255 } };
	const int64_t sectors = size / 512;
	for (unsigned i = 0; i < sizeof shapes / sizeof shapes[0]; i++) {
		const int64_t track = (int64_t)shapes[i][0] * shapes[i][1];
		if (sectors > 0 && sectors % track == 0 && sectors / track <= 65535) {
			*spt = shapes[i][0];
			*hpc = shapes[i][1];
			*cyl = (unsigned)(sectors / track);
			return;
		}
	}
	*spt = 63;
	*hpc = 16;
	*cyl = (unsigned)(sectors / (63 * 16));
}

static int refuse(const char *key, const char *what, const char *choices)
{
	snprintf(g_loadError, sizeof g_loadError, "%s" TEXT_ARG "%s" TEXT_ARG "%s", key, what, choices);
	return 0;
}

/* the memory card's size (an 8-bit machine with more memory than its
 * motherboard takes), for its memory domain */
static long g_cardKB;

static int compose_cfg(void)
{
	char machineName[64], bios[64], cpu[64], fpu[32], video[64], sound[64];
	char fddA[32], fddB[32], mouseName[32], joystickName[64], hdc[64];
	char slotA[256], slotB[256], slotHdd[256], slotCd[256], choices[1024];
	long mem;
	int m;

	setting_id("machine", "xi8088", machineName, sizeof machineName);
	m = machine_get_machine_from_internal_name(machineName);
	if (m < 0) {
		snprintf(g_loadError, sizeof g_loadError, "error.no_such_machine" TEXT_ARG "%s", machineName);
		return 0;
	}
	setting_id("bios", "auto", bios, sizeof bios);
	setting_id("cpu", "auto", cpu, sizeof cpu);
	setting_id("fpu", "none", fpu, sizeof fpu);
	mem = wbx_setting_long("memoryKB", 0);
	setting_id("video", "cga", video, sizeof video);
	setting_id("sound", "none", sound, sizeof sound);
	setting_id("floppyA", "525_2dd", fddA, sizeof fddA);
	setting_id("floppyB", "none", fddB, sizeof fddB);
	setting_id("mouse", "none", mouseName, sizeof mouseName);
	setting_id("joystick", "none", joystickName, sizeof joystickName);
	setting_id("hardDiskController", "none", hdc, sizeof hdc);

	g_cfgLen = 0;
	cfg_add("[General]\n");
	/* one millisecond of machine time a call of pc_run, as upstream runs */
	cfg_add("force_10ms = 0\n");
	cfg_add("fdd_sounds_enabled = 0\n");
	cfg_add("confirm_reset = 0\nconfirm_exit = 0\nconfirm_save = 0\n");

	cfg_add("\n[Machine]\n");
	cfg_add("machine = %s\n", machineName);
	if (strcmp(cpu, "auto")) {
		char family[64];
		const char *slash = strchr(cpu, '/');
		long speed = slash ? strtol(slash + 1, NULL, 10) : 0;
		snprintf(family, sizeof family, "%.*s", slash ? (int)(slash - cpu) : (int)strlen(cpu), cpu);
		if (!cpu_taken(m, family, speed, choices, sizeof choices))
			return refuse("error.cpu_not_taken", cpu, choices);
		cfg_add("cpu_family = %s\ncpu_speed = %ld\ncpu_multi = 0\n", family, speed);
	}
	cfg_add("fpu_type = %s\n", fpu);
	if (mem <= 0)
		mem = (long)machines[m].ram.max;   /* the most the motherboard takes */
	/* More than an 8-bit machine's motherboard takes (the IBM PC's 64 KB,
	 * the XT's 256 KB) is on a memory card, as it was on the real machines:
	 * 86Box's generic PC/XT memory expansion, from where the motherboard's
	 * ends, up to 640 KB in all. The BIOS counts it through the machine's
	 * switches, which 86Box sets from both. */
	long card = 0;
	g_cardKB = 0;
	if (mem > (long)machines[m].ram.max && !IS_AT(m)) {
		if (mem > 640)
			mem = 640;
		card = mem - (long)machines[m].ram.max;
		mem = (long)machines[m].ram.max;
		g_cardKB = card;
	}
	cfg_add("mem_size = %ld\n", mem);
	/* The recompiler (86Box's, for a 386-class processor and up) or the
	 * interpreter: two machines, not one, so the setting is part of a movie.
	 * It is there only in a build with -Ddynarec (meson_options.txt). */
#ifdef USE_DYNAREC
	cfg_add("cpu_use_dynarec = %d\n", wbx_setting_bool("recompiler", 0) ? 1 : 0);
#else
	cfg_add("cpu_use_dynarec = 0\n");   /* a build without it: the interpreter */
#endif
	/* the RTC is set at power-on from the project's date (patch 0001) */
	cfg_add("time_sync = utc\n");

	if (!device_taken(m, video, vid_dev, vid_name, choices, sizeof choices))
		return refuse("error.video_not_taken", video, choices);
	g_needsCharRom = !strcmp(video, "cga") || !strcmp(video, "mda") || !strcmp(video, "hercules");
	cfg_add("\n[Video]\ngfxcard = %s\n", video);

	if (!device_taken(m, sound, snd_dev, snd_name, choices, sizeof choices))
		return refuse("error.sound_not_taken", sound, choices);
	cfg_add("\n[Sound]\nsndcard = %s\n", sound);
	cfg_add("sound_type = int16\n");
	cfg_add("fm_driver = nuked\n");

	if (!device_taken(m, mouseName, mouse_dev, mouse_name, choices, sizeof choices))
		return refuse("error.mouse_not_taken", mouseName, choices);
	cfg_add("\n[Input devices]\nmouse_type = %s\njoystick_type = %s\n", mouseName, joystickName);

	if (!device_taken(m, hdc, hdc_dev, hdc_name, choices, sizeof choices))
		return refuse("error.hdc_not_taken", hdc, choices);
	/* "internal" is the motherboard's own IDE port, which only some
	 * machines have (86Box's table lets any machine name it) */
	if (!strcmp(hdc, "internal") && !(machines[m].flags & MACHINE_IDE_PRI))
		return refuse("error.hdc_not_taken", hdc, "none, xtide, xtide_at_1ch");
	if (card > 0)
		cfg_add("\n[Other peripherals]\nisamem0_type = genericxt\n"
		        "\n[Generic PC/XT Memory Expansion #1]\nsize = %ld\nstart = %ld\n", card, mem);
	cfg_add("\n[Storage controllers]\nfdc = internal\nhdc = %s\n", hdc);
	/* the XTIDE Universal BIOS build each controller reads: the plain one
	 * (the "+" build for a V20 is a choice 86Box offers; this core does not
	 * yet) */
	if (!strcmp(hdc, "xtide"))
		cfg_add("\n[PC/XT XTIDE]\nbios = xt\n");
	else if (!strcmp(hdc, "xtide_at_1ch"))
		cfg_add("\n[PC/AT XTIDE (Primary Only)]\nbios = at\n");

	/* the hard disk: a raw image, on the controller's first channel; what
	 * the machine writes to it stays in memory (chimera-overlay.c) */
	if (wbx_slot_first("hdd", slotHdd, sizeof slotHdd) && slotHdd[0]) {
		FILE *f = fopen(slotHdd, "rb");
		int64_t size = 0;
		unsigned spt, hpc, cyl;
		if (f) {
			fseeko(f, 0, SEEK_END);
			size = ftello(f);
			fclose(f);
		}
		if (!strcmp(hdc, "none")) {
			snprintf(g_loadError, sizeof g_loadError, "error.hdd_needs_controller" TEXT_ARG "%s", slotHdd);
			return 0;
		}
		hdd_geometry(size, &spt, &hpc, &cyl);
		cfg_add("\n[Hard disks]\nhdd_01_parameters = %u, %u, %u, 0, ide\nhdd_01_fn = %s\nhdd_01_ide_channel = 0:0\n",
		        spt, hpc, cyl, slotHdd);
	}

	cfg_add("\n[Floppy and CD-ROM drives]\n");
	cfg_add("fdd_01_type = %s\nfdd_02_type = %s\n", fddA, fddB);
	/* the CD-ROM drive: an ATAPI drive, the second drive of the hard disk
	 * controller (an XT-IDE card's first channel, slave), 86Box's own "86BOX
	 * CD-ROM" at 8x. Its audio is made in place (patch 0007). */
	if (wbx_slot_first("cdrom", slotCd, sizeof slotCd) && slotCd[0]) {
		if (!strcmp(hdc, "none")) {
			snprintf(g_loadError, sizeof g_loadError, "error.cdrom_needs_controller" TEXT_ARG "%s", slotCd);
			return 0;
		}
		cfg_add("cdrom_01_parameters = 1, atapi\ncdrom_01_ide_channel = 0:1\ncdrom_01_speed = 8\n"
		        "cdrom_01_image_path = %s\n", slotCd);
	}
	if (wbx_slot_first("floppy_a", slotA, sizeof slotA) && slotA[0])
		cfg_add("fdd_01_fn = %s\n", slotA);
	if (wbx_slot_first("floppy_b", slotB, sizeof slotB) && slotB[0])
		cfg_add("fdd_02_fn = %s\n", slotB);

	if (strcmp(bios, "auto")) {
		const device_config_t *bc = bios_config(m);
		int found = 0;
		choices[0] = 0;
		for (int b = 0; bc && b < 32 && bc->bios[b].files_no; b++) {
			if (bios_left_out(bc->bios[b].internal_name))
				continue;
			append(choices, sizeof choices, bc->bios[b].internal_name);
			if (!strcmp(bc->bios[b].internal_name, bios))
				found = 1;
		}
		if (!found)
			return refuse("error.bios_not_taken", bios, choices[0] ? choices : "-");
	}
	/* the machine's own options: its BIOS, and IBM's cassette BASIC (the
	 * IBM PC and XT read it from ROM files of their own when it is on) */
	{
		const device_t *md = machine_get_device(m);
		int has_basic = 0;
		for (const device_config_t *c = md ? md->config : NULL; c && c->type != CONFIG_END; c++)
			if (!strcmp(c->name, "enable_basic"))
				has_basic = 1;
		if (md && (strcmp(bios, "auto") || has_basic)) {
			cfg_add("\n[%s]\n", md->name);
			if (strcmp(bios, "auto"))
				cfg_add("bios = %s\n", bios);
			if (has_basic)
				cfg_add("enable_basic = %d\n", wbx_setting_bool("cassetteBasic", 1) ? 1 : 0);
		}
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

ECL_EXPORT const uint8_t *GetSaveDataScratch(void);
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
	/* invisible memory is taken during Init and never later */
	(void)GetSaveDataScratch();

	if (!compose_cfg())
		return 0;

	if (!pc_init(5, argv)) {
		snprintf(g_loadError, sizeof g_loadError, "error.start_failed");
		return 0;
	}

	/* The machine's ROMs. 86Box's own interface quietly switches to another
	 * machine or card whose ROMs are there (pc_init_modules), or runs on
	 * without a file; the core refuses instead, naming the files. */
	g_watchMissing = 1;
	g_missing[0] = g_asked[0] = 0;
	int have = machine_available(machine);
	g_watchMissing = 0;
	if (!have) {
		/* none of the machine's BIOS choices is there: name the chosen one's
		 * files when the machine has choices, else every file it looked for */
		const device_config_t *bc = bios_config(machine);
		snprintf(g_missing, sizeof g_missing, "%s", g_asked);
		if (bc) {
			char chosen[64];
			setting_id("bios", "auto", chosen, sizeof chosen);
			if (!strcmp(chosen, "auto"))
				snprintf(chosen, sizeof chosen, "%s", bc->default_string);
			g_missing[0] = 0;
			for (int b = 0; b < 32 && bc->bios[b].files_no; b++) {
				if (strcmp(bc->bios[b].internal_name, chosen))
					continue;
				for (int f = 0; f < bc->bios[b].files_no; f++) {
					char flat[512];
					append(g_missing, sizeof g_missing, chimera_flat_name(bc->bios[b].files[f], flat, sizeof flat));
				}
			}
		}
		snprintf(g_loadError, sizeof g_loadError, "error.roms_missing" TEXT_ARG "%s" TEXT_ARG "%s",
		         machine_getname(machine), g_missing);
		return 0;
	}
	g_watchMissing = 1;
	g_missing[0] = g_asked[0] = 0;
	have = video_card_available(gfxcard[0]);
	g_watchMissing = 0;
	if (!have) {
		snprintf(g_loadError, sizeof g_loadError, "error.roms_missing" TEXT_ARG "%s" TEXT_ARG "%s",
		         video_get_internal_name(gfxcard[0]), g_asked);
		return 0;
	}
	video_setblit(chimera_blit);
	pc_init_modules();
	/* Built: every ROM file the machine reads now must be there. (Being
	 * "available" is not enough: it is satisfied by any of a machine's BIOS
	 * choices, and the Xi 8088 set to its 128 KB BIOS with only the 64 KB
	 * file passed it and then ran with no BIOS at all - a black screen and
	 * no word, docs/PLAN.md.) */
	g_watchMissing = 1;
	g_missing[0] = 0;
	pc_reset_hard_init();
	g_watchMissing = 0;
	if (g_missing[0]) {
		snprintf(g_loadError, sizeof g_loadError, "error.roms_missing" TEXT_ARG "%s" TEXT_ARG "%s",
		         machine_getname(machine), g_missing);
		return 0;
	}
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

/* ------------------------------------------------------------ the CMOS
 *
 * An AT keeps its setup in the CMOS memory of its clock chip. A real owner
 * ran SETUP once; the core keeps no CMOS file, so 86Box starts every
 * machine with an empty one, and the IBM AT then stops at "161-System
 * Options Not Set" and the Award boards at "CMOS checksum error", each
 * waiting for F1. Patch 0009 calls this when 86Box finds no CMOS file (at
 * power-on and at a hard reset): the standard bytes every AT BIOS reads are
 * written from the project's settings, the way the PCem core does
 * (chimera-core-pcem, docs/CMOS.md). The rest stays as 86Box leaves it.
 * That is enough for the IBM AT. It is not for the two Award boards: their
 * BIOS also keeps a block of its own settings past these bytes, with its
 * own checksums (on the 486 board, 0x34-0x38 summed into 0x3A and a block
 * up to 0x55 summed into 0x56), so they still load their defaults and wait
 * for F1 (docs/PLAN.md).
 *
 *   0x0E        diagnostic status: no errors
 *   0x0F        shutdown status: a normal power-on
 *   0x10        floppy drive types, A in the high half, B in the low
 *   0x12, 0x19, 0x1A   fixed disk types: none (a disk is on an XT-IDE card,
 *               whose own BIOS finds it, or on an IDE port the BIOS
 *               detects; the AT's table of fourteen types is not used)
 *   0x14        equipment: drives, display, coprocessor, floppy present
 *   0x15-0x18   base and extended memory in KB
 *   0x2E-0x2F   the checksum of 0x10-0x2D, high byte first
 *   0x30-0x31   extended memory in KB again (outside the checksum)
 *
 * The XT-class machines have no CMOS, and other kinds of NVRAM are not
 * touched (86Box's nvrmask below 63). The native build's
 * CHIMERA_86BOX_EMPTY_CMOS leaves it empty: the test scripts' negative
 * control (the sandbox has no environment). */
static uint8_t *g_cmos;
static int g_cmosSize;

static int cmos_floppy_type(int drive)
{
	/* 86Box's drive -> the CMOS's: 0 none, 1 360K, 2 1.2M, 3 720K,
	 * 4 1.44M, 5 2.88M. A 5.25" 80-track double density drive (720K) is
	 * electrically a 3.5" 720K one; 3.5" 360K (one side) is 80 tracks too. */
	const char *n = fdd_get_internal_name(fdd_get_type(drive));
	if (!n || !strcmp(n, "none"))
		return 0;
	if (!strcmp(n, "525_1dd") || !strcmp(n, "525_2dd"))
		return 1;
	if (!strcmp(n, "525_2hd"))
		return 2;
	if (!strcmp(n, "525_2qd") || !strcmp(n, "35_1dd") || !strcmp(n, "35_2dd"))
		return 3;
	if (!strcmp(n, "35_2hd"))
		return 4;
	if (!strcmp(n, "35_2ed"))
		return 5;
	return 0;
}

void chimera_cmos_power_on(uint8_t *regs, int size)
{
	int a, b, n, video = 0, sum = 0;
	uint32_t base, ext;
	const char *card;

	if (size < 64 || machines[machine].nvrmask < 63)
		return;
	g_cmos = regs;
	g_cmosSize = size;
	if (getenv("CHIMERA_86BOX_EMPTY_CMOS"))
		return;

	a = cmos_floppy_type(0);
	b = cmos_floppy_type(1);
	/* display: 00 EGA or VGA (their own BIOS), 01 CGA 40x25, 10 CGA 80x25,
	 * 11 monochrome */
	card = video_get_internal_name(gfxcard[0]);
	if (card && (!strcmp(card, "mda") || !strcmp(card, "hercules")))
		video = 3;
	else if (card && !strcmp(card, "cga"))
		video = 2;
	n = (a ? 1 : 0) + (b ? 1 : 0);

	base = mem_size < 640 ? mem_size : 640;
	ext = mem_size > 1024 ? mem_size - 1024 : 0;
	if (ext > 0xffff)
		ext = 0xffff;

	regs[0x0e] = 0x00;
	regs[0x0f] = 0x00;
	for (int i = 0x10; i <= 0x2d; i++)
		regs[i] = 0x00;
	regs[0x10] = (uint8_t)((a << 4) | b);
	regs[0x14] = (uint8_t)((n ? (n - 1) << 6 : 0) | (video << 4) | (fpu_type != FPU_NONE ? 0x02 : 0) | (n ? 0x01 : 0));
	regs[0x15] = (uint8_t)(base & 0xff);
	regs[0x16] = (uint8_t)(base >> 8);
	regs[0x17] = (uint8_t)(ext & 0xff);
	regs[0x18] = (uint8_t)(ext >> 8);
	for (int i = 0x10; i <= 0x2d; i++)
		sum += regs[i];
	regs[0x2e] = (uint8_t)(sum >> 8);
	regs[0x2f] = (uint8_t)(sum & 0xff);
	regs[0x30] = (uint8_t)(ext & 0xff);
	regs[0x31] = (uint8_t)(ext >> 8);
}

/* for the tests: the CMOS as it is now (null on a machine without one) */
ECL_EXPORT const uint8_t *DebugCmos(void) { return g_cmos; }
ECL_EXPORT int DebugCmosSize(void) { return g_cmos ? g_cmosSize : 0; }

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

/* The memory: the motherboard's, and a memory card's when the machine has
 * one (the card's starts at the address where the motherboard's ends; 86Box
 * keeps it apart, in the card's own buffer, which is one block of memory
 * from that address on: _mem_exec holds where each 4 KB of it is). */
static uint8_t *card_memory(void)
{
	const uint32_t base = (uint32_t)mem_size * 1024;
	uint8_t *p = g_cardKB > 0 ? _mem_exec[base >> MEM_GRANULARITY_BITS] : NULL;
	for (uint32_t a = base; p && a < base + (uint32_t)g_cardKB * 1024; a += 1u << MEM_GRANULARITY_BITS)
		if (_mem_exec[a >> MEM_GRANULARITY_BITS] != p + (a - base))
			return NULL;
	return p;
}
ECL_EXPORT int GetMemoryDomainCount(void) { return card_memory() ? 2 : 1; }
ECL_EXPORT const char *GetMemoryDomainName(int i)
{
	return i == 0 ? "System RAM" : (i == 1 && card_memory()) ? "Memory Card RAM" : NULL;
}
ECL_EXPORT uint8_t *GetMemoryDomainPtr(int i) { return i == 0 ? ram : i == 1 ? card_memory() : NULL; }
ECL_EXPORT int64_t GetMemoryDomainSize(int i)
{
	return i == 0 ? (int64_t)mem_size * 1024 : (i == 1 && card_memory()) ? (int64_t)g_cardKB * 1024 : 0;
}
ECL_EXPORT int GetMemoryDomainWritable(int i) { return i == 0 || (i == 1 && card_memory()); }

/* The controls: chimera-input.c. */
ECL_EXPORT void SetButton(int32_t index, int32_t state) { chimera_set_button(index, state); }
ECL_EXPORT void SetAxis(int32_t index, int32_t value) { chimera_set_axis(index, value); }

/* -------------------------------------------- save data (docs/save-data.md)
 *
 * What a PC keeps is its disks: one file for each disk the machine opened
 * for writing, the whole image as it stands (the file and what the machine
 * wrote over it, chimera-overlay.c), under the name of the project's file it
 * came from. Handed back into the same slot, the machine carries on from it.
 *
 * It goes out through a window, not a pointer: an image of gigabytes is a
 * read-only file the sandbox streams plus a scatter of 4 KiB blocks, so
 * GetSaveDataFileBuffer answers null, which tells the engine to use
 * ReadSaveDataFile and GetSaveDataScratch (as the PCem core does). The
 * window is invisible memory: a view the host reads between frames, not
 * machine state. */
#define SAVEDATA_WINDOW (256 * 1024)
static uint8_t *g_saveWindow;

ECL_EXPORT int32_t GetSaveDataFileCount(void) { return (int32_t)chimera_overlay_count(); }
ECL_EXPORT const char *GetSaveDataFileName(int32_t index) { return chimera_overlay_name((int)index); }
ECL_EXPORT int64_t GetSaveDataFileSize(int32_t index) { return chimera_overlay_size((int)index); }
ECL_EXPORT const uint8_t *GetSaveDataFileBuffer(int32_t index) { (void)index; return NULL; }

ECL_EXPORT const uint8_t *GetSaveDataScratch(void)
{
	if (!g_saveWindow)
		g_saveWindow = (uint8_t *)alloc_invisible(SAVEDATA_WINDOW);
	return g_saveWindow;
}

ECL_EXPORT int64_t ReadSaveDataFile(int32_t index, int64_t offset, int64_t len)
{
	if (!GetSaveDataScratch() || len <= 0)
		return 0;
	if (len > SAVEDATA_WINDOW)
		len = SAVEDATA_WINDOW;
	return chimera_overlay_read((int)index, offset, g_saveWindow, len);
}
