# crux-marisa (Droidspaces build)

## Known limitations (4.14-openela base)

- **CFS bandwidth (`CONFIG_CFS_BANDWIDTH`)**: cannot be enabled — the vendor
  `CONFIG_SCHED_WALT` Kconfig hard-mutually-excludes it. Enabling it would
  require dropping WALT and breaks Xiaomi sched-freq behavior. Consequence:
  `docker run --cpus` is silently ignored. Use cgroup v2 `cpuset`, or
  `nice`/`ionice` as alternatives.
- **New mount API (`fsopen`/`fsconfig`)**: architecturally absent on 4.14
  (introduced in 5.2). systemd inside containers falls back to legacy syscalls;
  no functional impact observed.

## CI note: kernel/Makefile IKCONFIG patch

Xiaomi's vendor `kernel/Makefile` contains three `ifneq ($(CONFIG_MACH_XIAOMI_*),y)`
rules that re-point `$(obj)/config_data.gz` at static files under
`arch/arm64/configs/*_stock_defconfig` instead of the real build `.config`.
This makes the embedded `IKCONFIG` blob (and `/proc/config.gz`) always show the
stock config, regardless of what was actually compiled in. `.ci/build-kernel.sh`
(PYMK block) removes those rules at build time and restores the standard upstream
dependency on the out-of-tree `.config`. Without this patch, any defconfig /
fragment changes are invisible to config forensics even though the compiled
kernel itself may be correct.
