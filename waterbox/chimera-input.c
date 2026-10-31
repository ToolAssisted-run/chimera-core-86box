/* chimera-input.c - the controller: a PC keyboard, a mouse and two gameport
 * joysticks, and the one place their order lives.
 *
 * The order of buttons[] and of the axis enum (chimera.h) IS the order of
 * the package's declaration (waterbox.config "input"); tools/check-input.py
 * compares the two. The names and the order are the PCem core's, so a PC
 * movie's columns mean the same in both cores.
 *
 * Levels, not events: the frontend says what is held this frame, and a key
 * whose state changed since the last frame is pressed or released in
 * 86Box's keyboard (keyboard_input), in the order of the table. What was
 * held is ordinary memory, so a state carries it.
 */
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <86box/86box.h>
#include <86box/device.h>
#include <86box/timer.h>
#include <86box/keyboard.h>
#include <86box/mouse.h>
#include <86box/gameport.h>

#include "chimera.h"

typedef struct {
	const char *name;
	uint16_t scancode;   /* 86Box's: the XT code, 0x100 + it for an E0 key; 0 for no key */
} chimera_button_t;

static const chimera_button_t buttons[] = {
	{ "Escape", 0x01 },
	{ "1", 0x02 }, { "2", 0x03 }, { "3", 0x04 }, { "4", 0x05 }, { "5", 0x06 },
	{ "6", 0x07 }, { "7", 0x08 }, { "8", 0x09 }, { "9", 0x0A }, { "0", 0x0B },
	{ "Minus", 0x0C }, { "Equals", 0x0D }, { "Backspace", 0x0E }, { "Tab", 0x0F },
	{ "Q", 0x10 }, { "W", 0x11 }, { "E", 0x12 }, { "R", 0x13 }, { "T", 0x14 },
	{ "Y", 0x15 }, { "U", 0x16 }, { "I", 0x17 }, { "O", 0x18 }, { "P", 0x19 },
	{ "Left Bracket", 0x1A }, { "Right Bracket", 0x1B }, { "Enter", 0x1C },
	{ "Left Ctrl", 0x1D },
	{ "A", 0x1E }, { "S", 0x1F }, { "D", 0x20 }, { "F", 0x21 }, { "G", 0x22 },
	{ "H", 0x23 }, { "J", 0x24 }, { "K", 0x25 }, { "L", 0x26 },
	{ "Semicolon", 0x27 }, { "Apostrophe", 0x28 }, { "Backquote", 0x29 },
	{ "Left Shift", 0x2A }, { "Backslash", 0x2B },
	{ "Z", 0x2C }, { "X", 0x2D }, { "C", 0x2E }, { "V", 0x2F }, { "B", 0x30 },
	{ "N", 0x31 }, { "M", 0x32 }, { "Comma", 0x33 }, { "Period", 0x34 },
	{ "Slash", 0x35 }, { "Right Shift", 0x36 }, { "Keypad Multiply", 0x37 },
	{ "Left Alt", 0x38 }, { "Space", 0x39 }, { "Caps Lock", 0x3A },
	{ "F1", 0x3B }, { "F2", 0x3C }, { "F3", 0x3D }, { "F4", 0x3E }, { "F5", 0x3F },
	{ "F6", 0x40 }, { "F7", 0x41 }, { "F8", 0x42 }, { "F9", 0x43 }, { "F10", 0x44 },
	{ "Num Lock", 0x45 }, { "Scroll Lock", 0x46 },
	{ "Keypad 7", 0x47 }, { "Keypad 8", 0x48 }, { "Keypad 9", 0x49 }, { "Keypad Minus", 0x4A },
	{ "Keypad 4", 0x4B }, { "Keypad 5", 0x4C }, { "Keypad 6", 0x4D }, { "Keypad Plus", 0x4E },
	{ "Keypad 1", 0x4F }, { "Keypad 2", 0x50 }, { "Keypad 3", 0x51 },
	{ "Keypad 0", 0x52 }, { "Keypad Period", 0x53 },
	{ "F11", 0x57 }, { "F12", 0x58 },
	/* the E0 block */
	{ "Keypad Enter", 0x11C }, { "Right Ctrl", 0x11D }, { "Keypad Divide", 0x135 },
	{ "Print Screen", 0x137 }, { "Right Alt", 0x138 },
	{ "Home", 0x147 }, { "Up", 0x148 }, { "Page Up", 0x149 }, { "Left", 0x14B },
	{ "Right", 0x14D }, { "End", 0x14F }, { "Down", 0x150 }, { "Page Down", 0x151 },
	{ "Insert", 0x152 }, { "Delete", 0x153 },
	{ "Left Windows", 0x15B }, { "Right Windows", 0x15C }, { "Menu", 0x15D },
	/* not keys: handled by their index below */
	{ "Mouse Left", 0 }, { "Mouse Right", 0 }, { "Mouse Middle", 0 },
	{ "Joystick 1 Button 1", 0 }, { "Joystick 1 Button 2", 0 },
	{ "Joystick 2 Button 1", 0 }, { "Joystick 2 Button 2", 0 },
};
#define BUTTONS ((int)(sizeof buttons / sizeof buttons[0]))
#define FIRST_NOT_KEY (BUTTONS - 7)

const char *chimera_button_name(int index) { return index >= 0 && index < BUTTONS ? buttons[index].name : NULL; }
int chimera_button_count(void) { return BUTTONS; }

/* what the frontend says (two channels: the packed mask of FrameAdvance for
 * the first 64, SetButton for all; a frame is their union), and what the
 * machine was last told */
static uint8_t g_set[BUTTONS], g_packed[BUTTONS], g_down[0x200];
static int g_axis[CHIMERA_AXES];

void chimera_set_button(int index, int state)
{
	if (index >= 0 && index < BUTTONS)
		g_set[index] = state ? 1 : 0;
}

void chimera_set_packed(uint64_t packed)
{
	for (int i = 0; i < 64 && i < BUTTONS; i++)
		g_packed[i] = (uint8_t)((packed >> i) & 1);
}

static int held(int index) { return g_set[index] | g_packed[index]; }

/* ------------------------------------------------------------ the mouse
 *
 * 86Box's mice are relative: the movement handed to mouse_scale() is kept
 * until the device's reports have carried it all (mouse.c subtracts what a
 * report could take and keeps the rest), so a jump across the screen
 * arrives whole. A POSITION (Mouse Position X/Y, 0..65535 across the
 * picture) is turned into the movement that would reach it from the last
 * position, in pixels of the picture: open loop, as in the PCem and DOSBox-X
 * cores - a guest that accelerates the pointer or stops it at an edge is
 * not followed. A relative axis that moved this frame wins over the
 * position for its direction, and the position is remembered either way
 * (the DOSBox-X core's rule, its issue 61). */
static int g_lastPosX = -1, g_lastPosY = -1;

static int position_delta(int value, int screen, int *last)
{
	int px, moved;
	if (screen <= 0)
		return 0;
	px = (int)(((long long)value * screen) / 65536);
	moved = *last < 0 ? 0 : px - *last;   /* the first frame places nothing */
	*last = px;
	return moved;
}

void chimera_set_axis(int index, int value)
{
	if (index >= 0 && index < CHIMERA_AXES)
		g_axis[index] = value;
}

/* Called at the start of a frame, before the machine runs. */
void chimera_apply_input(int screenW, int screenH)
{
	uint8_t want[0x200];
	int i, dx, dy, mb = 0;

	memset(want, 0, sizeof want);
	for (i = 0; i < FIRST_NOT_KEY; i++)
		if (held(i))
			want[buttons[i].scancode] = 1;
	/* two buttons may name one key; the whole state is worked out before
	 * any of it is told, so a released one cannot cancel a held one */
	for (i = 0; i < FIRST_NOT_KEY; i++) {
		const uint16_t sc = buttons[i].scancode;
		if (want[sc] != g_down[sc]) {
			g_down[sc] = want[sc];
			keyboard_input(want[sc], sc);
		}
	}

	if (held(FIRST_NOT_KEY + 0))
		mb |= 1;
	if (held(FIRST_NOT_KEY + 1))
		mb |= 2;
	if (held(FIRST_NOT_KEY + 2))
		mb |= 4;
	mouse_set_buttons_ex(mb);

	dx = g_axis[CHIMERA_AXIS_MOUSE_X];
	dy = g_axis[CHIMERA_AXIS_MOUSE_Y];
	{
		const int px = position_delta(g_axis[CHIMERA_AXIS_MOUSE_POS_X], screenW, &g_lastPosX);
		const int py = position_delta(g_axis[CHIMERA_AXIS_MOUSE_POS_Y], screenH, &g_lastPosY);
		if (!dx)
			dx = px;
		if (!dy)
			dy = py;
	}
	if (dx || dy)
		mouse_scale(dx, dy);
}

/* ---------------------------------------------------------- joysticks
 *
 * Two sticks of two buttons on the first game port, as 86Box's interfaces
 * hand them over: axes from -32767 to 32767, buttons 0 or 1. The package's
 * axes run 0..65535 with 32767 at rest. */
static int stick(int v)
{
	v -= 32767;
	if (v > 32767)
		v = 32767;
	if (v < -32767)
		v = -32767;
	return v;
}

void chimera_joystick_process(uint8_t gp)
{
	for (int js = 0; js < 2 && js < MAX_JOYSTICKS; js++) {
		joystick_state_t *j = &joystick_state[gp][js];
		j->plat_joystick_nr = js + 1;
		if (gp != 0)
			continue;
		j->axis[0] = stick(g_axis[js ? CHIMERA_AXIS_JOY2_X : CHIMERA_AXIS_JOY1_X]);
		j->axis[1] = stick(g_axis[js ? CHIMERA_AXIS_JOY2_Y : CHIMERA_AXIS_JOY1_Y]);
		j->button[0] = held(FIRST_NOT_KEY + 3 + js * 2);
		j->button[1] = held(FIRST_NOT_KEY + 4 + js * 2);
		for (int p = 0; p < MAX_JOY_POVS; p++)
			j->pov[p] = -1;
	}
}

/* --------------------------------------------------------- lag frames
 *
 * A frame in which the machine read none of its controls is a lag frame.
 * The ports that are controls: the keyboard controller's data port (which
 * also carries a PS/2 mouse), the game port, the four serial ports' data
 * (a serial mouse), and the bus and InPort mice. */
int chimera_input_read;

void chimera_port_read(uint16_t port)
{
	switch (port) {
	case 0x60:
	case 0x201:
	case 0x3F8: case 0x2F8: case 0x3E8: case 0x2E8:
	case 0x23C: case 0x23D: case 0x23E: case 0x23F:
		chimera_input_read = 1;
		break;
	default:
		break;
	}
}
