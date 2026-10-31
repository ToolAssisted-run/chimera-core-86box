/* chimera-plat.c - 86Box's platform layer, for a Chimera core.
 *
 * 86Box asks its user interface for a set of services: open a file, give
 * memory, start a thread, take the sound, show the picture, say a message.
 * Upstream has one such layer per interface (src/qt, src/unix). This is the
 * core's: one thread, no host, every file a name mounted by the frontend.
 *
 * Built twice from this one file: into the sandboxed core and into the
 * native reference, which must be the same program. So nothing here asks the
 * host anything - not the time, not a directory, not whether a file may be
 * written - in either build.
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/mman.h>
#include <wchar.h>

#include <86box/86box.h>
#include <86box/device.h>
#include <86box/timer.h>
#include <86box/plat.h>
#include <86box/plat_dynld.h>
#include <86box/thread.h>
#include <86box/ui.h>
#include <86box/path.h>
#include <86box/gameport.h>
#include <86box/network.h>

#include "chimera.h"

/* ------------------------------------------------------------ globals */

/* what upstream's interfaces define and the emulator reads */
int  rctrl_is_lalt;
int  update_icons;
int  kbd_req_capture;
int  hide_status_bar;
int  hide_tool_bar;
int  fixed_size_x = 640;
int  fixed_size_y = 480;
int  mouse_capture;
/* config.c reads shader file names into this (MAX_USER_SHADERS, qt-glsl.h,
 * is 20); the core draws no shaders */
char gl3_shader_file[20][512];

joystick_state_t      joystick_state[GAMEPORT_MAX][MAX_JOYSTICKS];
plat_joystick_state_t plat_joystick_state[MAX_PLAT_JOYSTICKS];

/* ------------------------------------------------------- the file layer
 *
 * 86Box opens every file through plat_fopen: its configuration, the ROMs
 * (each under one of its ROM folders), the CMOS file, the disk images. In
 * the sandbox there are no folders, only files the frontend mounted under a
 * name, so a path is turned into the name it was mounted under:
 *
 *  - the configuration (CHIMERA_CFG_NAME) is not a file at all: the core
 *    composed it from the project's settings, and it is read from memory;
 *  - a ROM, ".../roms/machines/xi8088/bios-xi8088.bin", is the firmware the
 *    package declares under the id "machines_xi8088_bios-xi8088.bin": the
 *    path inside 86Box's ROM set with each '/' a '_' (the set has several
 *    files called bios.bin, so the folders have to stay in the name);
 *  - anything else is its last path element: a disk image a slot named.
 *
 * Nothing is ever written to a file: the frontend mounts every file
 * read-only, and the native reference must answer as the sandbox does. A
 * disk image opened for update ("rb+") gets a stream whose writes stay in
 * the machine's memory (chimera-overlay.c); a file 86Box would create or
 * replace (its CMOS file, its configuration) is simply not written. */

const char *chimera_flat_name(const char *path, char *out, size_t outsz)
{
	return chimera_flat_name_ex(path, out, outsz, NULL);
}

const char *chimera_flat_name_ex(const char *path, char *out, size_t outsz, int *is_rom)
{
	const char *r = NULL, *p;
	size_t i;
	for (p = path; (p = strstr(p, "roms/")) != NULL; p += 5)
		if (p == path || p[-1] == '/')
			r = p + 5;
	if (is_rom)
		*is_rom = r != NULL;
	if (r) {
		for (i = 0; i + 1 < outsz && r[i]; i++)
			out[i] = (r[i] == '/' || r[i] == '\\') ? '_' : r[i];
		out[i] = 0;
		return out;
	}
	p = path + strlen(path);
	while (p > path && p[-1] != '/' && p[-1] != '\\')
		p--;
	snprintf(out, outsz, "%s", p);
	return out;
}

/* The test scripts' negative control may hand a card another ROM (the
 * upstream build that does not find the drive): in the native build only,
 * through CHIMERA_86BOX_NO_BUILTIN_ROMS; the sandbox has no environment. */
const struct chimera_rom *chimera_builtin_rom(const char *name)
{
	if (getenv("CHIMERA_86BOX_NO_BUILTIN_ROMS"))
		return NULL;
	for (const struct chimera_rom *r = chimera_builtin_roms; r->name; r++)
		if (!strcmp(r->name, name))
			return r;
	return NULL;
}

static int writes(const char *mode)
{
	return strchr(mode, 'w') || strchr(mode, 'a') || strchr(mode, '+');
}

FILE *plat_fopen(const char *path, const char *mode)
{
	char name[1024];
	int rom = 0;
	if (!path || !mode)
		return NULL;
	chimera_flat_name_ex(path, name, sizeof name, &rom);
	if (!strcmp(name, CHIMERA_CFG_NAME))
		return writes(mode) ? NULL : chimera_cfg_open();
	if (writes(mode)) {
		/* a disk image the machine may write: its writes are kept in
		 * memory over the file (chimera-overlay.c); anything else 86Box
		 * would write (its configuration, the CMOS file) is not written */
		if (!rom && !strchr(mode, 'w') && !strchr(mode, 'a')) {
			FILE *f = chimera_overlay_open(name);
			chimera_file_opened(name, rom, f != NULL);
			if (f)
				return f;
		}
		errno = EACCES;
		return NULL;
	}
	if (!name[0])
		return NULL;
	/* "rt, ccs=UTF-8" and the like are Windows' modes: read is read */
	const struct chimera_rom *b = rom ? chimera_builtin_rom(name) : NULL;
	FILE *f = b ? fmemopen((void *)b->data, b->size, "rb") : fopen(name, "rb");
	chimera_file_opened(name, rom, f != NULL);
	return f;
}

FILE *plat_fopen64(const char *path, const char *mode) { return plat_fopen(path, mode); }

void plat_remove(char *path) { (void)path; }

int plat_getcwd(char *bufp, int max)
{
	snprintf(bufp, (size_t)max, "%s", CHIMERA_VM_PATH);
	return 1;
}

int plat_chdir(char *path) { (void)path; return 0; }

/* There are no folders, but 86Box asks whether its own exist: a path that
 * ends in a slash is one (the machine's folder, a ROM folder), and anything
 * else is a file. */
int plat_dir_check(char *path) { return path && path[0] && path[strlen(path) - 1] == '/'; }

/* "is it there?" - a question, not a read: a machine asks it of every ROM
 * file of every BIOS it could have (rom_present) */
int plat_file_check(const char *path)
{
	char name[1024];
	int rom = 0;
	chimera_flat_name_ex(path, name, sizeof name, &rom);
	if (!strcmp(name, CHIMERA_CFG_NAME))
		return 1;
	if (rom && chimera_builtin_rom(name))
		return 1;
	FILE *f = name[0] ? fopen(name, "rb") : NULL;
	chimera_file_asked(name, rom, f != NULL);
	if (!f)
		return 0;
	fclose(f);
	return 1;
}

int plat_dir_create(char *path) { (void)path; return 0; }

void plat_tempfile(char *bufp, char *prefix, char *suffix)
{
	sprintf(bufp, "%s-chimera%s", prefix ? prefix : "", suffix ? suffix : "");
}

void plat_get_exe_name(char *s, int size) { snprintf(s, (size_t)size, "%s86Box", CHIMERA_EXE_PATH); }
void plat_get_global_config_dir(char *outbuf, size_t len) { snprintf(outbuf, len, "%s", CHIMERA_VM_PATH); }
void plat_get_global_data_dir(char *outbuf, size_t len) { snprintf(outbuf, len, "%s", CHIMERA_VM_PATH); }
void plat_get_temp_dir(char *outbuf, uint8_t len) { snprintf(outbuf, len, "%s", CHIMERA_VM_PATH); }
void plat_get_vmm_dir(char *outbuf, size_t len) { snprintf(outbuf, len, "%s", CHIMERA_VM_PATH); }
void plat_init_rom_paths(void) {}
void plat_init_asset_paths(void) {}
int plat_is_block_device(const char *path) { (void)path; return 0; }
int64_t plat_get_block_device_size(const char *path) { (void)path; return 0; }

/* ------------------------------------------------- paths (as upstream's) */

void path_normalize(char *path) { (void)path; }

int path_abs(char *path) { return path[0] == '/'; }

void path_slash(char *path)
{
	if (path[0] && path[strlen(path) - 1] != '/')
		strcat(path, "/");
}

const char *path_get_slash(char *path)
{
	return (path[0] && path[strlen(path) - 1] != '/') ? "/" : "";
}

char *path_get_filename(char *s)
{
	int c = (int)strlen(s) - 1;
	while (c > 0) {
		if (s[c] == '/' || s[c] == '\\')
			return &s[c + 1];
		c--;
	}
	return s;
}

char *path_get_extension(char *s)
{
	int c = (int)strlen(s) - 1;
	if (c <= 0)
		return s;
	while (c && s[c] != '.')
		c--;
	if (!c)
		return &s[strlen(s)];
	return &s[c + 1];
}

void path_append_filename(char *dest, const char *s1, const char *s2)
{
	strcpy(dest, s1);
	path_slash(dest);
	strcat(dest, s2);
}

void path_get_dirname(char *dest, const char *path)
{
	int c = (int)strlen(path);
	const char *ptr = path;
	while (c > 0) {
		if (path[c] == '/' || path[c] == '\\') {
			ptr = &path[c];
			break;
		}
		c--;
	}
	while (path < ptr)
		*dest++ = *path++;
	*dest = '\0';
}

int stricmp(const char *s1, const char *s2) { return strcasecmp(s1, s2); }
int strnicmp(const char *s1, const char *s2, size_t n) { return strncasecmp(s1, s2, n); }

/* upstream's, from network/net_modem.c, which the core does not build (it
 * opens sockets on the host); ini.c trims every line of a configuration
 * with it */
char *trim(char *str)
{
	size_t len;
	char *frontp = str, *endp;
	if (str == NULL)
		return NULL;
	if (str[0] == '\0')
		return str;
	len = strlen(str);
	endp = str + len;
	while (isspace((unsigned char)*frontp))
		++frontp;
	if (endp != frontp) {
		while (isspace((unsigned char)*(--endp)) && endp != frontp) {
		}
	}
	if (frontp != str && endp == frontp)
		*str = '\0';
	else if (str + len - 1 != endp)
		*(endp + 1) = '\0';
	endp = str;
	if (frontp != str) {
		while (*frontp)
			*endp++ = *frontp++;
		*endp = '\0';
	}
	return str;
}

/* ----------------------------------------------------------- memory
 *
 * The machine's RAM and the recompiler's code buffer. Both are ordinary
 * guest memory, so a state carries them. Anonymous memory starts zeroed in
 * both builds. */
void *plat_mmap(size_t size, uint8_t executable)
{
	void *p = mmap(0, size, executable ? (PROT_READ | PROT_WRITE | PROT_EXEC) : (PROT_READ | PROT_WRITE),
	               MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
	return p == MAP_FAILED ? NULL : p;
}

void plat_munmap(void *ptr, size_t size) { munmap(ptr, size); }

/* -------------------------------------------------------------- time
 *
 * 86Box reads the host's clock for its speed statistics and a few timeouts
 * of the user interface. The core's clock is the machine's: milliseconds of
 * machine time, counted by the frame loop (chimera_ms). */
uint64_t plat_timer_read(void) { return chimera_ms; }
uint32_t plat_get_ticks(void) { return (uint32_t)chimera_ms; }
void plat_delay_ms(uint32_t count) { (void)count; }

/* ------------------------------------------------------------ threads
 *
 * One thread. The picture hand-over is done in place (patch 0003), and the
 * machines the core offers start no other thread. A thread 86Box asks for
 * anyway is not started: its name is kept, and Init refuses the machine,
 * naming it. Waits return at once - with nothing else running there is
 * nothing to wait for - and mutexes are free. */
static int g_dummy;
char chimera_thread_refused[128];

thread_t *thread_create_named(void (*thread_func)(void *param), void *param, const char *name)
{
	(void)thread_func;
	(void)param;
	if (!chimera_thread_refused[0])
		snprintf(chimera_thread_refused, sizeof chimera_thread_refused, "%s", name ? name : "?");
	fprintf(stderr, "86box: a device asked for a thread of its own (%s); the core has none to give\n", name);
	return &g_dummy;
}

int thread_wait(thread_t *arg) { (void)arg; return 0; }

typedef struct { int set; } chimera_event_t;

event_t *thread_create_event(void) { return calloc(1, sizeof(chimera_event_t)); }
void thread_set_event(event_t *arg) { if (arg) ((chimera_event_t *)arg)->set = 1; }
void thread_reset_event(event_t *arg) { if (arg) ((chimera_event_t *)arg)->set = 0; }
int thread_wait_event(event_t *arg, int timeout) { (void)arg; (void)timeout; return 0; }
void thread_destroy_event(event_t *arg) { free(arg); }

mutex_t *thread_create_mutex(void) { return &g_dummy; }
void thread_close_mutex(mutex_t *arg) { (void)arg; }
int thread_test_mutex(mutex_t *arg) { (void)arg; return 1; }
int thread_wait_mutex(mutex_t *arg) { (void)arg; return 1; }
int thread_release_mutex(mutex_t *arg) { (void)arg; return 1; }

void plat_set_thread_name(void *thread, const char *name) { (void)thread; (void)name; }

/* ---------------------------------------------------- the user interface */

void startblit(void) {}
void endblit(void) {}
void do_start(void) {}
void do_stop(void) {}
void plat_pause(int p) { dopause = p; }
void plat_mouse_capture(int on) { mouse_capture = on; }
int plat_vidapi(const char *name) { (void)name; return 0; }
char *plat_vidapi_name(int api) { (void)api; return "default"; }
void plat_resize_request(int x, int y, int monitor_index) { (void)x; (void)y; (void)monitor_index; }
void plat_resize(int x, int y, int monitor_index) { (void)x; (void)y; (void)monitor_index; }
int plat_language_code(char *langcode) { (void)langcode; return 0; }
void plat_language_code_r(int id, char *outbuf, int len) { (void)id; if (len > 0) outbuf[0] = 0; }
void plat_get_cpu_string(char *outbuf, uint8_t len) { snprintf(outbuf, len, "%s", "x86-64"); }

/* the guest switched the machine off (an ATX power-off): it stays on, as a
 * machine whose power button nobody presses again */
void plat_power_off(void) { chimera_powered_off = 1; }

char *plat_get_string(int id)
{
	switch (id) {
	case STRING_HW_NOT_AVAILABLE_MACHINE:
		return "Machine \"%s\" is not available: its ROMs are missing.";
	case STRING_HW_NOT_AVAILABLE_VIDEO:
		return "Video card \"%s\" is not available: its ROMs are missing.";
	case STRING_HW_NOT_AVAILABLE_DEVICE:
		return "Device \"%s\" is not available: its ROMs are missing.";
	case STRING_HW_NOT_AVAILABLE_TITLE:
		return "Hardware not available";
	case STRING_CDROM_OPEN_ISO_ERROR:
		return "Unable to open image \"%s\".";
	case STRING_CDROM_OPEN_CUE_ERROR:
		return "Unable to open cue sheet \"%s\".";
	case STRING_CDROM_OPEN_MDS_ERROR:
		return "Unable to open MDS file \"%s\".";
	case STRING_CDROM_LOAD_IMAGE_ERROR:
		return "Unable to load CD-ROM image \"%s\".";
	default:
		return "%s";
	}
}

/* A message 86Box would show in a box: logged, and the first one kept, so
 * that Init can pass it on when it refuses the machine. */
char chimera_first_message[512];

int ui_msgbox_header(int flags, char *header, char *message)
{
	(void)flags;
	fprintf(stderr, "86box: %s%s%s\n", header ? header : "", header ? ": " : "", message ? message : "");
	if (!chimera_first_message[0] && message)
		snprintf(chimera_first_message, sizeof chimera_first_message, "%s", message);
	return 0;
}

int ui_msgbox(int flags, char *message) { return ui_msgbox_header(flags, NULL, message); }

char *ui_window_title(char *s) { return s; }
void ui_hard_reset_completed(void) {}
void ui_init_monitor(int monitor_index) { (void)monitor_index; }
void ui_deinit_monitor(int monitor_index) { (void)monitor_index; }
void ui_sb_set_ready(int ready) { (void)ready; }
void ui_sb_update_panes(void) {}
void ui_sb_update_icon_write(int tag, int write) { chimera_drive_activity(tag, write); }
void ui_sb_update_icon_state(int tag, int state) { (void)tag; (void)state; }
void ui_sb_update_icon_wp(int tag, int state) { (void)tag; (void)state; }
void ui_sb_bugui(char *str) { (void)str; }

/* a drive's light: the status bar's tag says which drive */
void ui_sb_update_icon(int tag, int active) { chimera_drive_activity(tag, active); }

void plat_cdrom_ui_update(uint8_t id, uint8_t reload) { (void)id; (void)reload; }
void mo_eject(uint8_t id) { (void)id; }
void mo_reload(uint8_t id) { (void)id; }
void rdisk_eject(uint8_t id) { (void)id; }
void rdisk_reload(uint8_t id) { (void)id; }
void tape_eject(uint8_t id) { (void)id; }
void tape_reload(uint8_t id) { (void)id; }

/* no shared libraries are loaded: Ghostscript, mdsx and the rest are absent */
void *dynld_module(const char *name, dllimp_t *table) { (void)name; (void)table; return NULL; }
void dynld_close(void *handle) { (void)handle; }

/* ------------------------------------------------------------- sound
 *
 * 86Box hands over its streams when its own timers say: the cards at
 * 48000 Hz, the FM synthesizers at 49716 Hz, wavetables and CD audio at
 * 44100 Hz. chimera-audio.c gathers them into the frame's sound. */
void inital(void) {}
void closeal(void) {}
void givealbuffer(const void *buf) { chimera_audio_take(CHIMERA_STREAM_SOUND, (const int16_t *)buf); }
void givealbuffer_music(const void *buf) { chimera_audio_take(CHIMERA_STREAM_MUSIC, (const int16_t *)buf); }
void givealbuffer_wt(const void *buf) { chimera_audio_take(CHIMERA_STREAM_WAVETABLE, (const int16_t *)buf); }
void givealbuffer_cd(const void *buf) { chimera_audio_take(CHIMERA_STREAM_CD, (const int16_t *)buf); }
void givealbuffer_fdd(const void *buf, const uint32_t size) { (void)buf; (void)size; }
void givealbuffer_hdd(const void *buf, const uint32_t size) { (void)buf; (void)size; }

/* ---------------------------------------------------------- joysticks */

void joystick_init(void) {}
void joystick_close(void) {}
void joystick_process(uint8_t gp) { chimera_joystick_process(gp); }

/* ------------------------------------------------ devices left out
 *
 * Tables of devices name these, and the core does not build them: they
 * reach the host (a file, a pipe, a serial port, a network, the console) or
 * need a library the core does not carry. Each is a device that refuses to
 * start, so a configuration that asks for one gets nothing, as it would get
 * nothing from a device whose ROMs are missing. */
static void *refused_init(const device_t *info)
{
	fprintf(stderr, "86box: %s is not part of this core\n", info->name);
	return NULL;
}

#define REFUSED_DEVICE(sym, nm, inm) \
	const device_t sym = { .name = nm, .internal_name = inm, .flags = 0, .local = 0, .init = refused_init }

REFUSED_DEVICE(lpt_prt_text_device, "Generic Text Printer", "text_prt");
REFUSED_DEVICE(lpt_prt_escp_device, "Generic ESC/P Dot-Matrix Printer", "dot_matrix");
REFUSED_DEVICE(lpt_prt_ps_device, "Generic PostScript Printer", "postscript");
REFUSED_DEVICE(lpt_prt_pcl_device, "Generic PCL5e Printer", "pcl");
REFUSED_DEVICE(char_file_com_device, "File", "file");
REFUSED_DEVICE(char_file_lpt_device, "File", "file");
REFUSED_DEVICE(char_pipe_com_device, "Named pipe", "pipe");
REFUSED_DEVICE(char_pipe_lpt_device, "Named pipe", "pipe");
REFUSED_DEVICE(char_serial_passthrough_com_device, "Serial port passthrough", "serial_passthrough");
REFUSED_DEVICE(char_stdio_com_device, "Console", "stdio");
REFUSED_DEVICE(modem_device, "Standard Hayes-compliant Modem", "modem");

static void *refused_net(const netcard_t *card, const uint8_t *mac, void *priv, char *errbuf)
{
	(void)card; (void)mac; (void)priv;
	if (errbuf)
		strcpy(errbuf, "this core has no network");
	return NULL;
}
const netdrv_t net_pcap_drv = { .init = refused_net };
const netdrv_t net_slirp_drv = { .init = refused_net };
const netdrv_t net_switch_drv = { .init = refused_net };
int slirp_card_num;
int net_pcap_prepare(netdev_t *list) { (void)list; return 0; }
