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
# In-place merge of the droidspaces fragment. kconfig's conf program keeps the
# FIRST occurrence of a duplicated symbol when reading a .config, so appending
# fragment lines to the end of out/.config is silently ignored by olddefconfig.
# Instead: for each fragment symbol already present as "# X is not set", flip it
# in place; append only symbols that are absent entirely.
echo "# --- droidspaces fragment (in-place merge) ---"
python3 - <<'PYMERGE'
import re
frag = open('.ci/droidspaces.config').read().splitlines()
wanted = {}
for line in frag:
    m = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=([ym])$', line.strip())
    if m:
        wanted[m.group(1)] = m.group(2)
path = 'out/.config'
lines = open(path).read().splitlines()
seen = set()
out = []
for line in lines:
    m = re.match(r'^# (CONFIG_[A-Za-z0-9_]+) is not set$', line)
    if m and m.group(1) in wanted:
        out.append('%s=%s' % (m.group(1), wanted[m.group(1)]))
        seen.add(m.group(1))
        continue
    m2 = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=', line)
    if m2 and m2.group(1) in wanted:
        seen.add(m2.group(1))
        out.append('%s=%s' % (m2.group(1), wanted[m2.group(1)]))
        continue
    out.append(line)
missing = [k + '=' + v for k, v in sorted(wanted.items()) if k not in seen]
out.extend(missing)
open(path, 'w').write(chr(10).join(out) + chr(10))
print('fragment merged: flipped/kept %d, appended %d (%s)' % (len(seen), len(missing), [x.split('=')[0] for x in missing]))
PYMERGE
make "${MK[@]}" olddefconfig
# Post-olddefconfig verification: fail fast if any fragment symbol did not stick.
python3 - <<'PYVERIFY'
import re, sys
wanted = {}
for line in open('.ci/droidspaces.config'):
    m = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=([ym])$', line.strip())
    if m:
        wanted[m.group(1)] = m.group(2)
cur = {}
for line in open('out/.config'):
    m = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=(.*)$', line.strip())
    if m:
        cur.setdefault(m.group(1), m.group(2))
bad = [(k, cur.get(k, 'ABSENT')) for k, v in wanted.items() if cur.get(k) != v]
if bad:
    print('FRAGMENT NOT APPLIED:', bad)
    sys.exit(1)
print('fragment fully applied (%d symbols)' % len(wanted))
PYVERIFY
RC=$?
if [ "$RC" != 0 ]; then echo "::error::fragment merge failed"; exit 1; fi
# Snapshot the verified config, then REGENERATE it from scratch via
# KCONFIG_ALLCONFIG so that no vendor pre-baked .config copy step can clobber
# our fragment later in the build. `make allnoconfig KCONFIG_ALLCONFIG=...`
# resolves ONLY against our file + Kconfig deps; it does not run any product-
# specific defconfig hook.
cp out/.config out/.config.merged
rm -rf include/config include/generated out/include/config out/include/generated
make "${MK[@]}" allnoconfig >/dev/null
make KCONFIG_ALLCONFIG="$PWD/out/.config.merged" "${MK[@]}" alldefconfig
# Restore full-fidelity merged config as authoritative input, then sync.
cp out/.config.merged out/.config
make "${MK[@]}" olddefconfig
# Second verification pass on the regenerated config.
python3 - <<'PYVERIFY2'
import re, sys
wanted = {}
for line in open('.ci/droidspaces.config'):
    m = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=([ym])$', line.strip())
    if m:
        wanted[m.group(1)] = m.group(2)
cur = {}
for line in open('out/.config'):
    m = re.match(r'^(CONFIG_[A-Za-z0-9_]+)=(.*)$', line.strip())
    if m:
        cur.setdefault(m.group(1), m.group(2))
bad = [(k, cur.get(k, 'ABSENT')) for k, v in wanted.items() if cur.get(k) != v]
if bad:
    print('REGEN FRAGMENT LOST:', bad)
    sys.exit(1)
print('regen verified (%d symbols)' % len(wanted))
PYVERIFY2
RC=$?
if [ "$RC" != 0 ]; then echo "::error::regenerated config lost fragment symbols"; exit 1; fi
echo "::endgroup::"
echo "::group::audit key configs"
FAIL=0
for c in CONFIG_FHANDLE CONFIG_PID_NS CONFIG_USER_NS CONFIG_NET_NS \
         CONFIG_OVERLAY_FS CONFIG_CGROUP_DEVICE CONFIG_CGROUP_PIDS \
         CONFIG_NF_NAT CONFIG_QCOM_KGSL \
         CONFIG_SECCOMP_FILTER CONFIG_DEVTMPFS CONFIG_DEVTMPFS_MOUNT \
         CONFIG_MACVLAN CONFIG_IP6_NF_NAT CONFIG_IP6_NF_TARGET_MASQUERADE; do
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
# Debug: find which file carries the stock pre-baked config markers.
grep -l 'PRODUCT_CRUX is not set' arch/arm64/configs/* 2>/dev/null || true
md5sum out/.config
# Last-moment assertion: MACVLAN/IP6_NF must still be =y immediately before compile.
for c in CONFIG_MACVLAN CONFIG_IP6_NF_NAT CONFIG_IP6_NF_TARGET_MASQUERADE; do
  grep -qE "^$c=y" out/.config || { echo "::error::$c lost just before build"; md5sum out/.config; exit 1; }
done
if [ -f include/config/auto.conf ]; then grep -E '^CONFIG_(MACVLAN|IP6_NF_NAT)=' include/config/auto.conf || echo 'WARN: not in auto.conf'; fi
make "${MK[@]}" -j"$JOBS" Image.gz-dtb 2>&1 | tee build.log
# Post-build: verify the IKCFG blob embedded in the actual artifact.
python3 - <<'PYIKCFG'
import zlib, gzip, sys
raw = open('out/arch/arm64/boot/Image.gz-dtb','rb').read()
d = zlib.decompressobj(-15)
img = d.decompress(raw[10:])
i = img.find(b'IKCFG_ST')
if i < 0:
    print('NO IKCFG in artifact'); sys.exit(1)
seg = img[i+8:]
e = seg.find(b'IKCFG_ED')
try:
    cfg = gzip.decompress(seg[:e]).decode()
except Exception:
    cfg = zlib.decompressobj(-15).decompress(seg[10:e]).decode()
ok = True
for k in ['CONFIG_MACVLAN','CONFIG_IP6_NF_NAT','CONFIG_IP6_NF_TARGET_MASQUERADE']:
    hit = [l for l in cfg.splitlines() if l.startswith(k+'=') or l.startswith('# '+k+' is not set')]
    want = '%s=y' % k
    if want not in hit:
        print('IKCFG BAD:', k, hit); ok = False
    else:
        print('IKCFG OK:', k)
sys.exit(0 if ok else 1)
PYIKCFG
IKRC=$?
if [ "$IKRC" != 0 ]; then echo "::error::embedded IKCFG does not match fragment"; exit 1; fi
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
BOARD_CMDLINE="console=ttyMSM0,115200n8 earlycon=msm_geni_serial,0xa90000 androidboot.hardware=qcom androidboot.console=ttyMSM0 androidboot.memcg=1 lpm_levels.sleep_disabled=1 video=vfb:640x400,bpp=32,memsize=3072000 msm_rtb.filter=0x237 service_locator.enable=1 swiotlb=2048 loop.max_part=7 androidboot.usbcontroller=a600000.dwc3 buildvariant=user"
"$MKBOOTIMG" \
    --base 0x00000000 \
    --pagesize 4096 \
    --kernel out/arch/arm64/boot/Image.gz-dtb \
    --cmdline "$BOARD_CMDLINE" \
    --output out/boot.img
PACK_RC=$?
if [ "$PACK_RC" -ne 0 ] || [ ! -f out/boot.img ]; then
    echo "::error::boot.img packing failed (rc=$PACK_RC)"
    exit 1
fi
echo "::endgroup::"
ls -lh out/boot.img out/arch/arm64/boot/Image* 2>/dev/null || true