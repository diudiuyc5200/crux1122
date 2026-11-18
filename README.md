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
- **FCM3 VINTF kernel compliance**: the boot-time "device internal problem"
  dialog is triggered by `Build.isBuildConsistent()` failing libvintf kernel
  checks against `compatibility_matrix.3.xml`. Required and enforced by CI:
  `CONFIG_AUDIT=y` (also restores avc-denied logging), `CONFIG_FHANDLE=n`
  (note: FHANDLE is `default y` in kconfig, so it must be explicitly disabled
  in crux_defconfig; a fragment cannot express =n). Restored for parity with
  stock: PSTORE + CONSOLE/PMSG/RAM/ZLIB (ramoops crash forensics).
  Not applicable to this tree (structurally absent or stock-off): DEVKMEM
  (depends on !ARM64), SECURITY_PERF_EVENTS_RESTRICT (no such symbol),
  KPTI/SSBD/errata mitigations (stock ships them off).

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


## Bootloop lessons (hard rules for this tree)

Two config changes were proven to bootloop on real crux hardware and are permanently banned:

1. **CONFIG_PSTORE / PSTORE_RAM** (v3, Run #31): crux's merged DTB has no usable ramoops
   node; enabling pstore console backend hangs early boot. Never enable without adding a
   ramoops node in dts + memmap reservation.
2. **CONFIG_SECURITY_YAMA=y** (v6/v7, Runs #35/#36): YAMA LSM registration breaks vendor
   sepolicy assumptions at boot (stock ships it "not set"). Binary-search evidence: v7
   restored SYSFS_SYSCALL=y but kept YAMA=y and still bootlooped; SYSFS_SYSCALL=n is
   therefore NOT the culprit (v8 with SYSFS_SYSCALL=y boots fine).

General rule derived: only ADD pure networking/module symbols that have no stock conflict.
Never flip stock-y syscall-table/security/pstore symbols. FHANDLE=off is the single
exception, forced by FCM3 VINTF, verified safe on v4+.

## Final verdict on the boot dialog ("device internal problem")

Root cause: framework-side VINTF kernel compatibility check (ActivityManagerService.systemReady
-> Build.isBuildConsistent -> libvintf vs compatibility_matrix.3.xml). It is NON-FATAL, shows
once per boot.

After fixing every fixable violation (AUDIT=y, FHANDLE off, SYSFS_SYSCALL attempt reverted),
the remaining required symbols DO NOT EXIST in this 4.14 source tree and are equally absent
from the stock kernel:

- CONFIG_SECURITY_PERF_EVENTS_RESTRICT
- CONFIG_SYNC (= staging android sync was removed upstream; matrix expects the old name)
- CONFIG_ANDROID_PARANOID
- CONFIG_ARM64_UDF
- CONFIG_DEBUG_RODATA (renamed to SET_MODULE_DEPRECATED family in newer kernels)

Conclusion: the dialog cannot be eliminated from the kernel side on this ROM; it is a
pre-existing ROM/kernel-matrix inconsistency (present regardless of our build; confirmed
still showing after flashing back v2). Only remaining option if desired: Magisk module
patching Build.isBuildConsistent()/showSystemReadyErrorDialogs (userspace, out of scope
for this repo).

## Verified-good baseline

repacked_v8.img == Run #37 artifact, IKCFG byte-for-byte equal to v4 (Run #33) symbol set:
MACVLAN/IP6_NF_NAT/IP6_NF_TARGET_MASQUERADE =y (Droidspaces checks all green), AUDIT=y,
FHANDLE off, everything else stock. This is the release state of the project.
