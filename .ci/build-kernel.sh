#!/usr/bin/env bash
# Droidspaces build for crux-marisa A16 (4.14.357, Non-GKI, in-tree KernelSU)
# GitHub Actions ubuntu-22.04 + proton-clang
set -uo pipefail

WORKDIR="${WORKDIR:-$HOME/kernel-build}"
KERNEL_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEFCONFIG="crux_defconfig"
FRAGMENT="$KERNEL_DIR/.ci/droidspaces.config"
CLANG_BIN="$WORKDIR/proton-clang/bin"
ARCH=arm64
JOBS="$(nproc)"

cd "$KERNEL_DIR"
rm -rf out && mkdir -p out

echo "::group::defconfig + fragment"
make O=out ARCH=$ARCH CROSS_COMPILE=aarch64-linux-gnu- \
    CC="$CLANG_BIN/clang" LLVM=1 LLVM_IAS=1 "$DEFCONFIG"
bash "$KERNEL_DIR/scripts/kconfig/merge_config.sh" -m \
    "out/.config" "$FRAGMENT" || echo "::warning::merge_config had unmet symbols"
make O=out ARCH=$ARCH CROSS_COMPILE=aarch64-linux-gnu- \
    CC="$CLANG_BIN/clang" LLVM=1 LLVM_IAS=1 olddefconfig
echo "::endgroup::"

echo "::group::audit key configs"
for c in CONFIG_FHANDLE CONFIG_PID_NS CONFIG_USER_NS CONFIG_NET_NS \
         CONFIG_OVERLAY_FS CONFIG_CGROUP_DEVICE CONFIG_CGROUP_PIDS \
         CONFIG_CFS_BANDWIDTH CONFIG_NF_NAT CONFIG_QCOM_KGSL \
         CONFIG_KSU CONFIG_SECCOMP_FILTER; do
    grep -E "^$c=y|^$c=m|^# $c is" out/.config || echo "MISSING: $c"
done
echo "::endgroup::"

echo "::group::build Image.lz4-dtb"
make -j"$JOBS" O=out ARCH=$ARCH CROSS_COMPILE=aarch64-linux-gnu- \
    CC="$CLANG_BIN/clang" LD="$CLANG_BIN/ld.lld" \
    AR="$CLANG_BIN/llvm-ar" NM="$CLANG_BIN/llvm-nm" \
    OBJCOPY="$CLANG_BIN/llvm-objcopy" STRIP="$CLANG_BIN/llvm-strip" \
    LLVM=1 LLVM_IAS=1 Image.lz4-dtb 2>&1 | tee build.log
BUILD_RC=${PIPESTATUS[0]}
echo "::endgroup::"

if [ "$BUILD_RC" -ne 0 ]; then
    echo "::error::kernel build failed (rc=$BUILD_RC)"
    exit 1
fi

echo "::group::pack boot.img"
MKBOOTIMG="$WORKDIR/mkbootimg/mkbootimg.py"
BOARD_CMDLINE="$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "$KERNEL_DIR/.config" 2>/dev/null || true)"
[ -z "$BOARD_CMDLINE" ] && BOARD_CMDLINE="console=ttyMSM0,115200n8 androidboot.console=ttyMSM0 androidboot.hardware=qcom msm_rtb.filter=0x237 ehci-hcd.park=3 lpm_levels.sleep_disabled=1 androidboot.bootdevice=1d84000.ufshc earlycon=msm_geni_serial,0x880000 loop.max_part=7 cgroup.memory=nokmem buildvariant=user"

python3 "$MKBOOTIMG" \
    --base 0x00000000 \
    --pagesize 4096 \
    --dtb out/arch/arm64/boot/Image.lz4-dtb \
    --cmdline "$BOARD_CMDLINE" \
    --header_version 0 \
    --os_version 10 \
    --os_patch_level 2099-12 \
    --output out/boot.img
echo "::endgroup::"

ls -lh out/boot.img out/arch/arm64/boot/Image* || true
