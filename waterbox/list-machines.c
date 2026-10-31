/* list-machines.c - 86Box's own tables, as JSON, for the package's
 * declaration (tools/gen-config.py). Native only; never in the package.
 *
 *   list-machines <machine internal name>...
 *
 * For each machine: its name, memory, CPUs (family, speed, FPUs) as the
 * machine takes them, its BIOS choices and their files, and which video
 * cards, sound cards, mice and joysticks 86Box lets it have. What it prints
 * is read from the pinned 86Box, so the declaration cannot drift from it.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <86box/86box.h>
#include <86box/device.h>
#include <86box/timer.h>
#include <86box/machine.h>
#include <86box/video.h>
#include <86box/sound.h>
#include <86box/mouse.h>
#include <86box/gameport.h>
#include <86box/fdd.h>
#include "cpu.h"

static void str(const char *s)
{
	putchar('"');
	for (; s && *s; s++) {
		if (*s == '"' || *s == '\\')
			putchar('\\');
		if ((unsigned char)*s < 0x20)
			printf("\\u%04x", *s);
		else
			putchar(*s);
	}
	putchar('"');
}

static void list_devices(int m, const char *key, const device_t *(*get)(int), const char *(*name)(int))
{
	int first = 1;
	printf(", \"%s\": [", key);
	/* each table ends with an entry that has no device (and an empty name);
	 * the first ones may have none too ("none", "internal") */
	for (int c = 0; c < 4096; c++) {
		const device_t *d = get(c);
		if (!d && c > 1)
			break;
		if (!d && !name(c)[0])
			continue;
		if (d && !device_is_valid(d, m))
			continue;
		printf("%s{\"id\": ", first ? "" : ", ");
		str(name(c));
		printf(", \"name\": ");
		str(d ? d->name : name(c));
		printf("}");
		first = 0;
	}
	printf("]");
}

static const device_t *vid_dev(int c) { return video_card_getdevice(c); }
static const char *vid_name(int c) { return video_get_internal_name(c); }
static const device_t *snd_dev(int c) { return sound_card_getdevice(c); }
static const char *snd_name(int c) { return sound_card_get_internal_name(c); }
static const device_t *mouse_dev(int c) { return mouse_get_device(c); }
static const char *mouse_name(int c) { return mouse_get_internal_name(c); }

int main(int argc, char **argv)
{
	printf("{\"machines\": [\n");
	for (int a = 1; a < argc; a++) {
		const int m = machine_get_machine_from_internal_name(argv[a]);
		if (m < 0) {
			fprintf(stderr, "list-machines: no machine %s\n", argv[a]);
			return 1;
		}
		const machine_t *mc = &machines[m];
		printf("%s{\"id\": ", a > 1 ? ",\n" : "");
		str(mc->internal_name);
		printf(", \"name\": ");
		str(mc->name);
		printf(", \"ram\": {\"min\": %u, \"max\": %u, \"step\": %d}", mc->ram.min, mc->ram.max, mc->ram.step);
		printf(", \"internalVideo\": %s", (mc->flags & MACHINE_VIDEO) ? "true" : "false");
		printf(", \"videoOnly\": %s", (mc->flags & MACHINE_VIDEO_ONLY) ? "true" : "false");

		/* the CPUs: each family the machine takes, each speed in it */
		printf(", \"cpus\": [");
		int first = 1;
		for (int f = 0; cpu_families[f].package; f++) {
			const cpu_family_t *fam = &cpu_families[f];
			if (!cpu_family_is_eligible(fam, m))
				continue;
			for (int c = 0; fam->cpus[c].cpu_type; c++) {
				if (!cpu_is_eligible(fam, c, m))
					continue;
				const CPU *cpu = &fam->cpus[c];
				printf("%s{\"family\": ", first ? "" : ", ");
				str(fam->internal_name);
				printf(", \"familyName\": ");
				str(fam->name);
				printf(", \"manufacturer\": ");
				str(fam->manufacturer);
				printf(", \"name\": ");
				str(cpu->name);
				printf(", \"rspeed\": %u, \"multi\": %g, \"fpus\": [", cpu->rspeed, cpu->multi);
				for (int p = 0; cpu->fpus && cpu->fpus[p].name; p++) {
					printf("%s{\"id\": ", p ? ", " : "");
					str(cpu->fpus[p].internal_name);
					printf(", \"name\": ");
					str(cpu->fpus[p].name);
					printf("}");
				}
				printf("]}");
				first = 0;
			}
		}
		printf("]");

		/* the BIOS choices, when the machine has them */
		printf(", \"bios\": [");
		const device_t *dev = mc->device;
		first = 1;
		const char *dflt = NULL;
		for (const device_config_t *cfg = dev ? dev->config : NULL; cfg && cfg->type != CONFIG_END; cfg++) {
			if (cfg->type != CONFIG_BIOS)
				continue;
			dflt = cfg->default_string;
			for (int b = 0; b < 32 && cfg->bios[b].files_no; b++) {
				const device_config_bios_t *bi = &cfg->bios[b];
				printf("%s{\"id\": ", first ? "" : ", ");
				str(bi->internal_name);
				printf(", \"name\": ");
				str(bi->name);
				printf(", \"files\": [");
				for (int f = 0; f < bi->files_no; f++) {
					printf("%s", f ? ", " : "");
					str(bi->files[f]);
				}
				printf("]}");
				first = 0;
			}
		}
		printf("], \"biosDefault\": ");
		if (dflt)
			str(dflt);
		else
			printf("null");
		printf(", \"biosSection\": ");
		if (dev)
			str(dev->name);
		else
			printf("null");

		list_devices(m, "video", vid_dev, vid_name);
		list_devices(m, "sound", snd_dev, snd_name);
		list_devices(m, "mouse", mouse_dev, mouse_name);
		printf(", \"joystick\": [");
		/* the table ends with no joystick: no name (index 0 is "none") */
		for (int j = 0; joystick_get_name(j); j++) {
			printf("%s{\"id\": ", j ? ", " : "");
			str(joystick_get_internal_name(j));
			printf(", \"name\": ");
			str(joystick_get_name(j));
			printf("}");
		}
		printf("], \"floppyDrives\": [");
		for (int t = 0; fdd_get_internal_name(t) && t < 64; t++) {
			if (!fdd_get_internal_name(t)[0])
				break;
			printf("%s{\"id\": ", t ? ", " : "");
			str(fdd_get_internal_name(t));
			printf(", \"name\": ");
			str(fdd_getname(t));
			printf("}");
		}
		printf("]}");
	}
	printf("\n]}\n");
	return 0;
}
