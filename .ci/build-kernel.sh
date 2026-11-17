#!/usr/bin/env bash
# Droidspaces build for crux-marisa A16 (4.14.357, Non-GKI, in-tree KernelSU)
# GitHub Actions ubuntu-22.04 + proton-clang
# Strategy: pure out-of-tree via O=out for ALL makes (never cd into out/ without O=,
# which would make srctree=".." and trip prepare3). Source tree is mrproper-cleaned first.
set -uo pipefail
WORKDIR="${WORKDIR:-$HOME/kernel-build}"
KERNEL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFCONFIG="crux_defconfig"
FRAGMENT="$KERNEL_DIR/.ci/droidspaces.config"
CLANG_BIN="$WORKDIR/proton-clang/bin"
ARCH=arm64
JOBS="$(nproc)"
MK=(O=out ARCH=$ARCH
  CC="$CLANG_BIN/clang" LD="$CLANG_BIN/ld.lld"
  AR="$CLANG_BIN/llvm-ar" NM="$CLANG_BIN/llvm-nm"
  OBJCOPY="$CLANG_BIN/llvm-objcopy" STRIP="$CLANG_BIN/llvm-strip"
  LLVM=1 LLVM_IAS=1 CLANG_TRIPLE=aarch64-linux-gnu-
  CROSS_COMPILE=aarch64-linux-gnu-)
cd "$KERNEL_DIR"
echo "::group::clean source tree"
make ARCH=$ARCH mrproper >/dev/null 2>&1 || true
rm -rf out .config .config.old
rm -f include/config/auto.conf
rm -rf include/config include/generated
mkdir -p out
echo "::endgroup::"
echo "::group::defconfig + fragment"
make "${MK[@]}" "$DEFCONFIG"
echo "# --- droidspaces fragment (manual merge) ---" >> out/.config
cat "$FRAGMENT" >> out/.config
make "${MK[@]}" olddefconfig
echo "::endgroup::"
echo "::group::audit key configs"
FAIL=0
for c in CONFIG_FHANDLE CONFIG_PID_NS CONFIG_USER_NS CONFIG_NET_NS \
         CONFIG_OVERLAY_FS CONFIG_CGROUP_DEVICE CONFIG_CGROUP_PIDS \
         CONFIG_NF_NAT CONFIG_QCOM_KGSL \
         CONFIG_SECCOMP_FILTER CONFIG_DEVTMPFS CONFIG_DEVTMPFS_MOUNT; do
    if grep -qE "^$c=[ym]" out/.config; then
        grep -E "^$c=" out/.config
    else
        echo "MISSING: $c"; FAIL=1
    fi
done
grep -E '^CONFIG_KSU=[ym]' out/.config || { echo 'MISSING: CONFIG_KSU'; FAIL=1; }
if [ "$FAIL" = 1 ]; then echo "::error::required configs missing"; exit 1; fi
echo "::endgroup::"
echo "::group::build Image.gz-dtb"
make "${MK[@]}" -j"$JOBS" Image.gz-dtb 2>&1 | tee build.log
BUILD_RC=${PIPESTATUS[0]}
echo "::endgroup::"
if [ "$BUILD_RC" -ne 0 ]; then
    echo "::error::kernel build failed (rc=$BUILD_RC)"
    grep -nE 'error:|Error|FAILED' build.log | tail -40 || true
    exit 1
fi
echo "::group::pack boot.img"
MKBOOTIMG="$HOME/kernel-build/mkbootimg/mkbootimg"
if [ ! -x "$MKBOOTIMG" ]; then echo "::error::mkbootimg binary not found at $MKBOOTIMG"; exit 1; fi
echo "using $MKBOOTIMG"
BOARD_CMDLINE="cgroup_disable=pressure console=ttyMSM0,115200n8 androidboot.console=ttyMSM0 androidboot.hardware=qcom msm_rtb.filter=0x237 ehci-hcd.park=3 lpm_levels.sleep_disabled=1 androidboot.bootdevice=1d84000.ufshc earlycon=msm_geni_serial,0x880000 loop.max_part=7 buildvariant=user"
python3 "$MKBOOTIMG" \
    --base 0x00000000 \
    --pagesize 4096 \
    --dtb out/arch/arm64/boot/Image.gz-dtb \
    --cmdline "$BOARD_CMDLINE" \
    --output out/boot.img
PACK_RC=$?
if [ "$PACK_RC" -ne 0 ] || [ ! -f out/boot.img ]; then
    echo "::error::boot.img packing failed (rc=$PACK_RC)"
    exit 1
fi
echo "::endgroup::"
ls -lh out/boot.img out/arch/arm64/boot/Image* 2>/dev/null || true
