// SPDX-License-Identifier: GPL-2.0
/* Compat stub: in-kernel LMK driver removed from this tree (userspace lmkd),
 * but mm/page_alloc.c and mm/vmscan.c reference lmk_kill_possible() when
 * CONFIG_ANDROID_LOW_MEMORY_KILLER=y. Trivial definition keeps the config
 * enabled for /proc/config.gz parity without changing behaviour.
 */
#include <linux/export.h>
#include <linux/types.h>
#include <linux/mm.h>

bool lmk_kill_possible(void)
{
	return false;
}
EXPORT_SYMBOL(lmk_kill_possible);
