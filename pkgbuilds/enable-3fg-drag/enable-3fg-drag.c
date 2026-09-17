/*
 * enable-3fg-drag — turn on libinput's native three-finger dragging in
 * Wayland compositors that don't expose the option themselves.
 *
 * WHAT
 * ----
 * libinput has shipped real, macOS-style three-finger dragging since v1.28
 * (Feb 2025): three fingers down = left button held, motion = drag, and
 * (since v1.31) a *fast* three-finger move is still a swipe. The drag is
 * synthesised inside libinput, so the compositor just receives ordinary
 * pointer button + motion events — nothing else has to understand it.
 *
 * WHY A SHIM
 * ----------
 * The feature is DISABLED by default and can only be turned on by the
 * process that owns the libinput context (the compositor), via
 *   libinput_device_config_3fg_drag_set_enabled().
 * As of early 2026 no mainstream desktop calls it: KWin (Plasma 6.7) does
 * not (KWin issue #59), and GNOME has only an open feature request. There
 * is no config file, environment variable, or quirk to flip it. So the
 * only way in on a stock desktop is to reach into the compositor's own
 * libinput context.
 *
 * HOW
 * ---
 * This LD_PRELOAD shim interposes libinput_get_event(). Whenever the
 * compositor's libinput announces a newly added device that supports
 * >= 3-finger drag, we enable it (ENABLED_3FG) on that device. Every event
 * — including the DEVICE_ADDED one — is returned untouched; we only set one
 * config property as a side effect. Non-touchpad devices report a finger
 * count of 0 and are left alone.
 *
 * The shim is COMPOSITOR-AGNOSTIC: it hooks a standard libinput API, so it
 * works for any libinput-based Wayland compositor (KWin, Mutter, wlroots…).
 *
 * NO HARD DEPENDENCY
 * ------------------
 * Every libinput function is resolved lazily through RTLD_NEXT, so this
 * object links against nothing but libc/libdl. In any process that is not
 * a libinput consumer, libinput_get_event() is never called and the shim
 * does literally nothing — which makes even a system-wide
 * /etc/ld.so.preload install cheap and safe.
 */

#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <libinput.h> /* types + enums only; no functions are linked */

struct libinput_event *libinput_get_event(struct libinput *li)
{
	static struct libinput_event *(*real)(struct libinput *);
	static enum libinput_event_type (*get_type)(struct libinput_event *);
	static struct libinput_device *(*get_device)(struct libinput_event *);
	static int (*get_finger_count)(struct libinput_device *);
	static enum libinput_config_status (*set_enabled)(
		struct libinput_device *, enum libinput_config_3fg_drag_state);
	static const char *(*dev_name)(struct libinput_device *);
	static const char *(*status_str)(enum libinput_config_status);
	static int resolved;

	if (!resolved) {
		resolved = 1;
		real = dlsym(RTLD_NEXT, "libinput_get_event");
		get_type = dlsym(RTLD_NEXT, "libinput_event_get_type");
		get_device = dlsym(RTLD_NEXT, "libinput_event_get_device");
		get_finger_count = dlsym(
			RTLD_NEXT, "libinput_device_config_3fg_drag_get_finger_count");
		set_enabled = dlsym(
			RTLD_NEXT, "libinput_device_config_3fg_drag_set_enabled");
		dev_name = dlsym(RTLD_NEXT, "libinput_device_get_name");
		status_str = dlsym(RTLD_NEXT, "libinput_config_status_to_str");
	}
	if (!real)
		return NULL; /* not a libinput consumer, or libinput missing */

	struct libinput_event *ev = real(li);
	if (ev && get_type && get_device && get_finger_count && set_enabled &&
	    get_type(ev) == LIBINPUT_EVENT_DEVICE_ADDED) {
		struct libinput_device *dev = get_device(ev);
		if (get_finger_count(dev) >= 3) {
			enum libinput_config_status st = set_enabled(
				dev, LIBINPUT_CONFIG_3FG_DRAG_ENABLED_3FG);
			fprintf(stderr,
				"[enable-3fg-drag] enabled 3-finger drag on \"%s\": %s\n",
				dev_name ? dev_name(dev) : "?",
				status_str ? status_str(st) : "");
		}
	}
	return ev;
}
