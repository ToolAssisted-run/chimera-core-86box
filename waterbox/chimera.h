/* chimera.h - what the core's own files share: the platform layer
 * (chimera-plat.c) and the guest interface (cinterface.c). */
#ifndef CHIMERA_86BOX_H
#define CHIMERA_86BOX_H

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

/* The machine's folder, and the program's, as 86Box is told them. Neither
 * exists: every path under them is turned into a mounted file's name
 * (chimera_flat_name). */
#define CHIMERA_VM_PATH  "/vm/"
#define CHIMERA_EXE_PATH "/86box/"
/* the configuration the core composes from the project's settings */
#define CHIMERA_CFG_NAME "86box.cfg"

/* the platform layer */
const char *chimera_flat_name(const char *path, char *out, size_t outsz);
const char *chimera_flat_name_ex(const char *path, char *out, size_t outsz, int *is_rom);
extern char chimera_thread_refused[128];
extern char chimera_first_message[512];

/* the guest interface */
extern uint64_t chimera_ms;           /* milliseconds of machine time run */
extern int chimera_powered_off;
FILE *chimera_cfg_open(void);
void chimera_file_opened(const char *name, int rom, int found);
void chimera_drive_activity(int tag, int active);

/* the controller (chimera-input.c); the axes in the declaration's order */
enum { CHIMERA_AXIS_MOUSE_X, CHIMERA_AXIS_MOUSE_Y, CHIMERA_AXIS_MOUSE_POS_X, CHIMERA_AXIS_MOUSE_POS_Y,
       CHIMERA_AXIS_JOY1_X, CHIMERA_AXIS_JOY1_Y, CHIMERA_AXIS_JOY2_X, CHIMERA_AXIS_JOY2_Y, CHIMERA_AXES };
void chimera_set_button(int index, int state);
void chimera_set_packed(uint64_t packed);
void chimera_set_axis(int index, int value);
void chimera_apply_input(int screenW, int screenH);
void chimera_joystick_process(uint8_t gameport);
void chimera_port_read(uint16_t port);
const char *chimera_button_name(int index);
int chimera_button_count(void);
extern int chimera_input_read;

enum { CHIMERA_STREAM_SOUND, CHIMERA_STREAM_MUSIC, CHIMERA_STREAM_WAVETABLE, CHIMERA_STREAM_CD,
       CHIMERA_STREAMS };
void chimera_audio_take(int stream, const int16_t *buf);
void chimera_audio_frame_start(void);
int16_t *chimera_audio_buffer(void);
int chimera_audio_pairs(void);

/* The C library's random numbers, as 86Box asks for them (rand and srand
 * are renamed to these in every C file of upstream's the core compiles): one
 * generator for both builds, whose state is machine memory. */
int chimera_rand(void);
void chimera_srand(unsigned seed);

#endif
