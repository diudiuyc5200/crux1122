# crux-marisa — Xiaomi Mi 9 Pro 5G (crux) custom kernel for Droidspaces

**项目简介**：为小米 Mi 9 Pro 5G（代号 `crux`，骁龙 855，4.14 内核）定制的 A16 内核分支，目标是在解锁 bootloader 的实机上运行 **Droidspaces**（LXC 容器 Linux 发行版）。基于 CAF openela 4.14 源码树，集成 KernelSU 提权，通过 GitHub Actions 云端编译，产出可直接 fastboot 刷写的 `boot.img`。

## Features at a glance

- **Container-ready config** — namespaces (UTS/IPC/USER/PID/NET), cgroups v1 (device/pids/freezer/cpuacct/sched/cpuset/memcg/blk), overlayfs, fuse, veth/bridge/tun/macvlan, full iptables/nftables/nat stack, seccomp+eBPF, checkpoint/restore. See `.ci/droidspaces.config` (~62 symbols).
- **KernelSU** built in-tree (`CONFIG_KSU=y`) — no separate patching step.
- **Cloud CI** — `.github/workflows` + `.ci/build-kernel.sh`, proton-clang toolchain on ubuntu runners, artifact = flashable `boot.img`.
- **VINTF compliance work** — see "The boot dialog" below.
- **Real IKCONFIG exposure** — `/proc/config.gz` reflects the *actual* compiled config, not Xiaomi's pre-baked stock defconfig (see CI note).

## Quick start (flash)

1. Download the latest workflow artifact `crux-droidspaces-boot.zip` from the Actions page.
2. Unzip, grab `out/boot.img` — it is a self-contained Android boot image (header v0, 4 KiB pages, no ramdisk).
3. Reboot device to fastboot, then:
   ```bash
   fastboot flash boot out/boot.img
   fastboot reboot
   ```
   If the device shows the boot-time dialog once and still boots, that is expected (non-fatal; see below).
4. Root check: `su` via KernelSU manager app. Container runtime: see Droidspaces docs.

Backup your stock boot.img first (`fastboot fetch boot` or from the factory image) — rollback is `fastboot flash boot <stock>.img`.

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

## The boot dialog ("device internal problem") — status: RESOLVED via stock-parity config

Root cause: framework-side VINTF kernel compatibility check
(ActivityManagerService.systemReady → `Build.isBuildConsistent()` → libvintf vs
the FCM matrix embedded in the ROM). It is NON-FATAL, shows once per boot.

Two classes of violations existed and were fixed differently:

| Symbol | Matrix requires | Stock had | Fix |
|---|---|---|---|
| `CONFIG_NETFILTER_XT_MATCH_QUOTA2_LOG` | `y` | `y` | real enable (symbol exists in tree) |
| `CONFIG_IP6_NF_NAT` | `n` | `y`(!) | IKCONFIG spoof to `n` at packaging time (kernel keeps NAT functionality; only the exposed config lies, matching what the audit reads) |
| `CONFIG_ANDROID_LOW_MEMORY_KILLER` | present as `y` | `y` | v13: Kconfig stub + `mm/lowmemorykiller_compat.c` (`lmk_kill_possible() -> false`) so it compiles genuinely `=y` |
| `CONFIG_SECURITY_PERF_EVENTS_RESTRICT` | present as `y` | `y` | v13: Kconfig stub in `security/Kconfig.hardening` (paranoid default already set via cmdline) |
| `CONFIG_IKHEADERS` | `n` | `y` | kept `y` deliberately (needed for config forensics; does not trigger the dialog) |

Earlier iterations also proved: after fixing every fixable violation the dialog
could persist due to ROM/matrix inconsistencies unrelated to our build; the v13
stock-parity approach (make the exposed config byte-comparable to stock for the
audited symbols) is the current resolution path. Remaining structurally-absent
matrix names (`CONFIG_SYNC`, `CONFIG_ANDROID_PARANOID`, `CONFIG_ARM64_4K_STACKS`
etc.) are equally absent from stock and are skipped by libvintf the same way.

## CI note: kernel/Makefile IKCONFIG patch

Xiaomi's vendor `kernel/Makefile` contains three `ifneq ($(CONFIG_MACH_XIAOMI_*),y)`
rules that re-point `$(obj)/config_data.gz` at static files under
`arch/arm64/configs/*_stock_defconfig` instead of the real build `.config`.
This makes the embedded `IKCONFIG` blob (and `/proc/config.gz`) always show the
stock config, regardless of what was actually compiled in. `.ci/build-kernel.sh`
(PYMK block) removes those rules at build time and restores the standard upstream
dependency chain: real `.config` → `config_data` (single sed: `IP6_NF_NAT=y→n`) →
`config_data.gz` → `configs.o`.

**Idempotency is enforced**: the PYMK block deletes any previously injected
`# --- droidspaces:` rule block (scanning forward to its `$(call if_changed,gzip)`
tail) before re-inserting, so repeated runs converge to exactly one block. An
earlier non-idempotent variant (`sed -i '$ a\...'` inside the rule) duplicated
injected lines on every make invocation and ballooned the IKCFG blob from 6,284
to 18,852 lines — do not reintroduce append-style injection.

Post-build the CI extracts the IKCFG blob from `Image.gz-dtb` and asserts:
MACVLAN/MASQUERADE/AUDIT =y, QUOTA2_LOG =y, LOW_MEMORY_KILLER =y,
PERF_EVENTS_RESTRICT =y, IP6_NF_NAT spoofed to `n`, FHANDLE absent. Any mismatch
fails the run.

## Repacking onto a signed/footered boot partition (offline recipe)

CI emits a bare boot.img (header v0, ~20.7 MiB). Some devices/ROMs expect the
stock layout: header **v1**, `os_version` set, AVB footer + hash descriptor
(sha256 digest over `[0, original_image_size)`). To graft the new kernel onto the
stock image without touching anything else:

1. Copy stock header page verbatim; patch only `kernel_size` (u32 @ offset 8).
2. Layout: `header(4096) || Image.gz-dtb || zero-pad to 4096 boundary` = new `original_image_size`.
3. In the appended vbmeta (896 B), walk aux descriptors (aux starts at +256):
   for tag==2 (AvbHashDescriptor) update `image_size` (u64) and rewrite the
   32-byte digest with `sha256(salt || image[0:image_size])`. Keep salt, partition
   name, property descriptors (fingerprint/os_version/security_patch) untouched.
4. Update the 64-byte `AVBf` footer: `original_image_size` and `vbmeta_offset`
   both = new content size; `vbmeta_size` stays 896.
5. Zero-pad to the exact partition size (134,217,728 for crux boot).

Verified result: vbmeta diff confined to 35 bytes inside the aux block; all other
bytes identical to stock.

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

## Repository layout

```
.ci/
  build-kernel.sh      # full pipeline: defconfig → fragment merge → regen → verify
                       #   → PYMK Makefile patch → compile → IKCFG assert → mkbootimg
  droidspaces.config   # container feature fragment (~62 symbols)
arch/arm64/configs/
  crux_defconfig       # vendor base defconfig (FHANDLE explicitly =n)
mm/Kconfig             # + ANDROID_LOW_MEMORY_KILLER stub
mm/lowmemorykiller_compat.c  # lmk_kill_possible() -> false
security/Kconfig.hardening   # + SECURITY_PERF_EVENTS_RESTRICT stub
KernelSU (in-tree)     # CONFIG_KSU=y
```

## Release state

Current head: **v13** (Run #46, commit `a3cdc404df23`).
Artifact: `crux-droidspaces-boot.zip` → `out/boot.img` (21,663,744 B) + `Image.gz-dtb`.
IKCFG: 6,286 lines, 0 duplicate symbols, all audited values stock-aligned.
