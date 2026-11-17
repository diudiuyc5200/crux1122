#!/usr/bin/env bash
# Droidspaces build for crux-marisa A16 (4.14.357, Non-GKI, in-tree KernelSU)
# GitHub Actions ubuntu-22.04 + proton-clang
set -uo pipefail

WORKDIR="${WORKDIR:-$HOME/kernel-build}"
KERNEL_DIR="$(git rev-parse --show-toplevel)"
DEFCONFIG="crux_defconfig"
FRAGMENT="$KERNEL_DIR/.ci/droidspaces.config"
CLANG_BIN="$WORKDIR/proton-clang/bin"
ARCH=arm64
JOBS="$(nproc)"
MAKE_COMMON=(O=out ARCH=$ARCH
  CC="$CLANG_BIN/clang" LD="$CLANG_BIN/ld.lld"
  AR="$CLANG_BIN/llvm-ar" NM="$CLANG_BIN/llvm-nm"
  OBJCOPY="$CLANG_BIN/llvm-objcopy" STRIP="$CLANG_BIN/llvm-strip"
  LLVM=1 LLVM_IAS=1 CLANG_TRIPLE=aarch64-linux-gnu-
  CROSS_COMPILE=aarch64-linux-gnu-)

cd "$KERNEL_DIR"
rm -rf out && mkdir -p out

echo "::group::defconfig + fragment"
make "${MAKE_COMMON[@]}" "$DEFCONFIG"
bash scripts/kconfig/merge_config.sh -m out/.config "$FRAGMENT" \
  || echo "::warning::merge_config had unmet symbols"
make "${MAKE_COMMON[@]}" olddefconfig
echo "::endgroup::"

echo "::group::audit key configs"
FAIL=0
for c in CONFIG_FHANDLE CONFIG_PID_NS CONFIG_USER_NS CONFIG_NET_NS \
         CONFIG_OVERLAY_FS CONFIG_CGROUP_DEVICE CONFIG_CGROUP_PIDS \
         CONFIG_CFS_BANDWIDTH CONFIG_NF_NAT CONFIG_QCOM_KGSL \
         CONFIG_SECCOMP_FILTER; do
    if grep -qE "^$c=[ym]" out/.config; then
        grep -E "^$c=" out/.config
    else
        echo "MISSING: $c"; FAIL=1
    fi
done
# KSU is tristate; built-in preferred
grep -E '^CONFIG_KSU=[ym]' out/.config || { echo 'MISSING: CONFIG_KSU'; FAIL=1; }
[ "$FAIL" = 1 ] && echo "::warning::some required configs missing" || true
echo "::endgroup::"

echo "::group::build Image.gz-dtb + dtbo"
make -j"$JOBS" "${MAKE_COMMON[@]}" Image.gz-dtb 2>&1 | tee build.log
BUILD_RC=${PIPESTATUS[0]}
if [ "$BUILD_RC" -eq 0 ] && [ -f out/arch/arm64/boot/dtbo.img ]; then
    echo "dtbo.img built"
fi
echo "::endgroup::"

if [ "$BUILD_RC" -ne 0 ]; then
    echo "::error::kernel build failed (rc=$BUILD_RC)"
    tail -50 build.log
    exit 1
fi

echo "::group::pack boot.img"
MKBOOTIMG="$WORKDIR/mkbootimg/mkbootimg.py"
BOARD_CMDLINE="cgroup_disable=pressure console=ttyMSM0,115200n8 androidboot.console=ttyMSM0 androidboot.hardware=qcom msm_rtb.filter=0x237 ehci-hcd.park=3 lpm_levels.sleep_disabled=1 androidboot.bootdevice=1d84000.ufshc earlycon=msm_geni_serial,0x880000 loop.max_part=7 buildvariant=user"

python3 "$MKBOOTIMG" \
    --base 0x00000000 \
    --pagesize 4096 \
    --dtb out/arch/arm64/boot/Image.gz-dtb \
    --cmdline "$BOARD_CMDLINE" \
    --header_version 0 \
    --os_version 10 \
    --os_patch_level 2099-12 \
    --output out/boot.img
echo "::endgroup::"

ls -lh out/boot.img out/arch/arm64/boot/Image* out/arch/arm64/boot/dtbo.img 2>/dev/null || true
