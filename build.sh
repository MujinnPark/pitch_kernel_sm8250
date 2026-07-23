#!/bin/bash
# Some logics of this script are copied from [scripts/build_kernel]. Thanks to UtsavBalar1231.

# Ensure the script exits on error
set -e

TOOLCHAIN_PATH=$HOME/neutron-clang/bin
GIT_COMMIT_ID=$(git rev-parse --short=8 HEAD)
TARGET_DEVICE=$1

if [ -z "$1" ]; then
  echo "Error: No argument provided, please specific a target device."
  echo "If you need KernelSU, please add [ksu] as the second arg."
  echo "Examples:"
  echo " Build for lmi(K30 Pro/POCO F2 Pro) without KernelSU:"
  echo " bash build.sh lmi"
  echo " Build for umi(Mi10) with KernelSU:"
  echo " bash build.sh umi ksu"
  exit 1
fi

if [ ! -d $TOOLCHAIN_PATH ]; then
  echo "TOOLCHAIN_PATH [$TOOLCHAIN_PATH] does not exist."
  echo "Please ensure the toolchain is there, or change TOOLCHAIN_PATH in the script to your toolchain path."
  exit 1
fi
echo "TOOLCHAIN_PATH: [$TOOLCHAIN_PATH]"
export PATH="$TOOLCHAIN_PATH:$PATH"

if ! command -v clang >/dev/null 2>&1; then
  echo "[clang] does not exist, please check your environment."
  exit 1
fi

# PitchKernel: PITCHKERNEL_NO_CCACHE=1 is a diagnostic escape hatch to test
# whether ccache's subprocess/pipe handling is the cause of the
# "LLVM ERROR: IO failure on output stream: Broken pipe" pattern documented
# in detail further below (search PITCHKERNEL_NO_CCACHE). When set, this
# entire masquerade block is skipped: no symlinks created, PATH untouched,
# so `command -v clang` resolves straight to $TOOLCHAIN_PATH/clang with no
# ccache in front of it. Normal builds (this var unset) are completely
# unaffected -- this only changes behavior when explicitly opted into.
if [ "${PITCHKERNEL_NO_CCACHE:-0}" == "1" ]; then
  echo "PITCHKERNEL_NO_CCACHE=1 -- DIAGNOSTIC: skipping ccache masquerade entirely, compiling with real clang directly (no cache reuse, not a normal build path)."
else
# ccache uses the masquerade method (symlinks named clang/clang++ that shadow
# the real compiler on PATH), not the prefix method (CC="ccache clang").
# The prefix method cannot work here: MAKE_ARGS is expanded unquoted below
# (make $MAKE_ARGS ...) so it gets word-split before make ever sees it --
# any embedded quotes around "ccache clang" become literal characters in
# the token stream, not shell grouping. Confirmed failure: make read
# CC="ccache and clang" as two separate targets, producing
# "target 'clang\"' given more than once in the same rule" / "No rule to
# make target 'clang clang'". Masquerade avoids this: CC stays "clang",
# ccache intercepts because its symlink is first on PATH.
#
# The masquerade symlinks are created fresh here (not relied upon from
# build.yml's Setup ccache step) so this script is self-contained and the
# collision risk is controlled directly: only the pinned /usr/local/bin/ccache
# binary is symlinked, and this directory is prepended, not appended, so it
# wins over any other ccache/clang on PATH.
#
# CCACHE_DIR, CCACHE_MAXSIZE, CCACHE_COMPILERCHECK, CCACHE_SLOPPINESS,
# CCACHE_BASEDIR are set by build.yml's "Build kernel" step env: block.
# Do not re-export or override them here.
if ! command -v ccache >/dev/null 2>&1; then
  echo "[ccache] not found on PATH. build.yml's 'Setup ccache' step must run before build.sh."
  exit 1
fi
CCACHE_REAL_BIN="$(command -v ccache)"
CCACHE_MASQ_DIR="$HOME/.ccache-masquerade"
mkdir -p "$CCACHE_MASQ_DIR"
ln -sf "$CCACHE_REAL_BIN" "$CCACHE_MASQ_DIR/clang"
ln -sf "$CCACHE_REAL_BIN" "$CCACHE_MASQ_DIR/clang++"
export PATH="$CCACHE_MASQ_DIR:$PATH"
echo "CCACHE_DIR: [$CCACHE_DIR]"
echo "ccache resolved to: [$CCACHE_REAL_BIN] ($(ccache --version | head -1))"
echo "clang now resolves through masquerade to: [$(command -v clang)]"
which -a clang 2>/dev/null || type -a clang
ccache -z
fi

# PitchKernel: DIAGNOSIS CORRECTED (see history below -- do not re-add an
# LTO thread cap without re-reading this).
#
# Original theory: CONFIG_LTO_CLANG=y without CONFIG_THINLTO means full/
# monolithic LTO, whose codegen backend spawns its own worker threads,
# contending with make -j$(nproc) on this 4-core runner and producing
# "LLVM ERROR: IO failure on output stream: Broken pipe". Tried capping
# threads via KBUILD_LDFLAGS=-mllvm -threads=N: nproc/2 (2 threads) took
# the count from 463 -> 376 (~19%); threads=1 (fully serialized) took it
# to 304. A real thread-contention cause should collapse to ~0 once fully
# serialized. It didn't -- proof the LTO theory was wrong, not just
# imperfectly tuned.
#
# Actual evidence (from the full 10262-line captured build log, run
# 79952562307, artifact pitchkernel-build-step-log): the 304 occurrences
# span from line 294 to line 9959 -- essentially the entire file -- and
# each one sits directly between two unrelated, ordinary `CC`/`HOSTCC`
# lines (e.g. between smp.o and sha256-core.o, between filemap.o and
# bpf_lsm.o). The kernel's single full-LTO link/codegen pass happens once,
# at the very end, after every .o file compiles -- these errors are
# scattered through ordinary per-file parallel compilation instead, which
# rules out LTO codegen as the mechanism entirely. The LTO thread cap has
# been removed; it was solving the wrong problem.
#
# Every single one of the 7753 CC/HOSTCC invocations in that build log
# went through the ccache masquerade wrapper below (clang is symlinked to
# ccache, so ccache is the one directly spawning and piping every real
# clang subprocess under make -j4 parallel load). That is the next actual
# suspect implicated by the evidence, not a new guess: ccache managing 4
# concurrent compiler subprocesses' stdout/stderr pipes is a mechanism
# that plausibly produces exactly this symptom (LLVM aborts hard, non-
# recoverably, on any EPIPE while writing a diagnostic -- confirmed
# upstream behavior, see llvm-project#174173 and #73014), and ccache sits
# directly in that path for every affected line.
#
# PITCHKERNEL_NO_CCACHE=1 (see the real gate around line 43 above, which
# actually skips the masquerade) is checked there; if the broken-pipe count
# drops to 0 with ccache out of the loop, ccache's subprocess/pipe handling
# is confirmed as the real cause. If it does NOT drop to 0, ccache is
# cleared too, and the next place to look is GitHub Actions' own log-
# streaming/forwarding of the runner's stdout, which is the only other
# thing that touches every one of these lines regardless of which file is
# being compiled.

MAKE_ARGS="ARCH=arm64 \
SUBARCH=arm64 \
O=out \
CC=clang \
HOSTCC=clang \
CLANG_TRIPLE=aarch64-linux-gnu- \
CROSS_COMPILE=aarch64-linux-gnu- \
CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
LD=ld.lld \
AR=llvm-ar \
NM=llvm-nm \
OBJCOPY=llvm-objcopy \
OBJDUMP=llvm-objdump \
STRIP=llvm-strip"

# PitchKernel: "LLVM ERROR: IO failure on output stream: Broken pipe"
# (present in every build for an extended period, 463/376/304/452/319
# occurrences observed across different diagnostic runs) was root-caused to
# the compiler toolchain itself, not anything in this script or build.yml:
#   - Not full LTO codegen: never actually enabled in any build this script
#     produces. Both build paths (AOSP and MIUI) run `scripts/config -d
#     LTO_CLANG -e LTO_NONE` immediately before their real `make` call,
#     unconditionally overriding munch_defconfig's CONFIG_LTO_CLANG=y.
#   - Not ccache: bypassing it entirely (PITCHKERNEL_NO_CCACHE=1) made the
#     error count worse (304 -> 452), not better.
#   - Not make -j parallelism: fully serial (PITCHKERNEL_SERIAL_BUILD=1,
#     -j1, zero concurrent clang processes) still produced 319 occurrences.
#   - Not make's SIGPIPE-ignore-for-children behavior (make >=4.4) -- the
#     GHA ubuntu-24.04 runner's make is 4.3.
# Actual cause: the CI workflow (build.yml, "Setup ZyCromerZ Clang" step)
# was installing Neutron clang 23.0.0git, a development snapshot from an
# unreleased commit, rather than a numbered stable release. Switching to
# ZyCromerZ Clang 16.0.6-20260510 (a stable release) eliminated the error
# entirely -- 0 occurrences, full pipeline green including SUSFS
# verification and release publish (run 80019238803). The dev snapshot
# carried some flavor of clang's documented raw_ostream/EPIPE hard-abort
# behavior (llvm-project#174173, #73014) that the stable release doesn't
# trigger under this build's actual I/O pattern.
#
# PITCHKERNEL_NO_CCACHE and PITCHKERNEL_SERIAL_BUILD flags below remain
# available for future re-diagnosis if a different broken-pipe-class issue
# ever appears, but should stay unset for normal builds -- both make builds
# significantly slower for no benefit now that this question is closed.
JOBS="$(nproc)"
if [ "${PITCHKERNEL_SERIAL_BUILD:-0}" == "1" ]; then
  JOBS=1
  echo "PITCHKERNEL_SERIAL_BUILD=1 -- DIAGNOSTIC: forcing -j1 (fully serial build, no concurrent clang processes). This will be much slower than normal."
fi

if [ "$1" == "j1" ]; then
  make $MAKE_ARGS -j1
  exit
fi
if [ "$1" == "continue" ]; then
  make $MAKE_ARGS -j"$JOBS"
  exit
fi

if [ ! -f "arch/arm64/configs/${TARGET_DEVICE}_defconfig" ]; then
  echo "No target device [${TARGET_DEVICE}] found."
  echo "Avaliable defconfigs, please choose one target from below down:"
  ls arch/arm64/configs/*_defconfig
  exit 1
fi

# Check clang is existing.
echo "[clang --version]:"
clang --version

KSU_ZIP_STR=NoKernelSU
if [ "$2" == "ksu" ]; then
  KSU_ENABLE=1
  KSU_ZIP_STR=ReSukiSU-SuSFS
else
  KSU_ENABLE=0
fi

echo "TARGET_DEVICE: $TARGET_DEVICE"

if [ $KSU_ENABLE -eq 1 ]; then
  echo "KSU is enabled"
  curl -LSs "https://raw.githubusercontent.com/ReSukiSU/ReSukiSU/main/kernel/setup.sh" | bash
else
  echo "KSU is disabled"
fi

echo "Integrating Baseband-guard..."
curl -LSs "https://github.com/vc-teahouse/Baseband-guard/raw/main/setup.sh" | bash
sed -i '/^config LSM$/,/^help$/{ /^[[:space:]]*default/ { /baseband_guard/! s/selinux/selinux,baseband_guard/ } }' security/Kconfig

echo "Cleaning..."
rm -rf out/
rm -rf anykernel/

echo "Clone AnyKernel3 for packing kernel (repo: https://github.com/AstideLabs/AnyKernel3)"
git clone https://github.com/AstideLabs/AnyKernel3 -b master --single-branch --depth=1 anykernel
sed -i 's/kernel\.string=.*/kernel.string=PitchKernel by MujinnPark/' anykernel/anykernel.sh || true

# ------------- Building for AOSP -------------
echo "Building for AOSP......"
make $MAKE_ARGS ${TARGET_DEVICE}_defconfig
echo "--- PitchKernel diagnostic: CONFIG_SCHED_WALT state after defconfig ---"
grep -E "^CONFIG_SCHED_WALT|^# CONFIG_SCHED_WALT" out/.config || echo "PitchKernel diagnostic: CONFIG_SCHED_WALT not present in out/.config at all"

if [ $KSU_ENABLE -eq 1 ]; then
  scripts/config --file out/.config \
    -e KSU \
    -e THREAD_INFO_IN_TASK \
    -e KSU_SUSFS \
    -e KSU_SUSFS_SUS_PATH \
    -e KSU_SUSFS_SUS_MOUNT \
    -e KSU_SUSFS_SUS_KSTAT \
    -e KSU_SUSFS_SPOOF_UNAME \
    -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -e KSU_SUSFS_OPEN_REDIRECT \
    -e KSU_SUSFS_SUS_MAP \
    -e KSU_MULTI_MANAGER_SUPPORT \
    -e KPM
else
  scripts/config --file out/.config -d KSU
fi

scripts/config --file out/.config \
  -e BBG

# --- TCP congestion control: build in BBR + switchable alternatives ---
# DEFAULT_TCP_CONG intentionally not set directly below: it's a Kconfig
# 'string' derived from the DEFAULT_BBR/DEFAULT_CUBIC/etc. choice block
# (see net/ipv4/Kconfig), not an independent setting. A previous attempt
# to explain this placed the comment INSIDE the backslash-continued
# scripts/config call below, which silently truncated the command at
# the first uncontinued comment line (no trailing backslash), causing
# 'build.sh: line NNN: -e: command not found' in CI. Comment moved
# above the command entirely so it can't break the continuation again.
scripts/config --file out/.config \
  -e TCP_CONG_ADVANCED \
  -e TCP_CONG_BBR \
  -e TCP_CONG_CUBIC \
  -e TCP_CONG_WESTWOOD \
  -e TCP_CONG_HTCP \
  -e TCP_CONG_BIC \
  -e DEFAULT_BBR \
  -d DEFAULT_CUBIC \
  -e NET_SCH_FQ \
  -e NET_SCH_FQ_CODEL
# --- end TCP congestion control ---

scripts/config --file out/.config \
  -e REKERNEL \
  -e REKERNEL_NETWORK
scripts/config --file out/.config \
  -d LTO_CLANG \
  -e LTO_NONE

# Reconcile .config non-interactively after manual scripts/config edits.
# Without this, any choice block Kconfig considers ambiguous (e.g. the
# TCP_CONG default) makes syncconfig prompt interactively during the
# real build step below, which has no stdin in CI and crashes with
# "Error in reading or end of file." olddefconfig silently accepts
# every current answer and defaults anything unresolved.
make $MAKE_ARGS olddefconfig
echo "--- PitchKernel diagnostic: CONFIG_SCHED_WALT state after olddefconfig ---"
grep -E "^CONFIG_SCHED_WALT|^# CONFIG_SCHED_WALT" out/.config || echo "PitchKernel diagnostic: CONFIG_SCHED_WALT not present in out/.config at all"
grep -n "KSU_SUSFS" out/.config | head -5

make $MAKE_ARGS -j"$JOBS"

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "The file [out/arch/arm64/boot/Image] exists. AOSP Build successfully."
else
  echo "The file [out/arch/arm64/boot/Image] does not exist. Seems AOSP build failed."
  exit 1
fi

echo "Generating [out/arch/arm64/boot/dtb]......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb

rm -rf anykernel/kernels/
mkdir -p anykernel/kernels/aosp/

# Patch for SukiSU KPM support.
if [ $KSU_ENABLE -eq 1 ]; then
  cd out/arch/arm64/boot/
  wget https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.13.0/patch_linux
  chmod +x patch_linux
  ./patch_linux
  rm Image
  mv oImage Image
  cd -
fi

cp out/arch/arm64/boot/Image anykernel/kernels/aosp/
cp out/arch/arm64/boot/dtb anykernel/kernels/aosp/
cp out/arch/arm64/boot/dtbo.img anykernel/kernels/aosp/

cd anykernel
ZIP_FILENAME=PitchKernel_AOSP_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip
zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip
mv $ZIP_FILENAME ../
cd ..
echo "Build for AOSP finished."
# ------------- End of Building for AOSP -------------
# If you don't need AOSP you can comment out the above block [Building for AOSP]

# ------------- Building for MIUI -------------
echo "Clearning [out/] and build for MIUI....."

dts_source=arch/arm64/boot/dts/vendor/qcom

# Backup dts
cp -a ${dts_source} .dts.bak

# Correct panel dimensions on MIUI builds
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<154>/<1537>/g' ${dts_source}/dsi-panel-j2*
sed -i 's/<155>/<1544>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<155>/<1545>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<155>/<1546>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-k11a-38-08-0a-dsc-cmd.dtsi
sed -i 's/<70>/<695>/g' ${dts_source}/dsi-panel-l11r-38-08-0a-dsc-cmd.dtsi
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j1s*
sed -i 's/<71>/<710>/g' ${dts_source}/dsi-panel-j2*

# Enable back mi smartfps while disabling qsync min refresh-rate
sed -i 's/\/\/ mi,mdss-dsi-pan-enable-smart-fps/mi,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ mi,mdss-dsi-smart-fps-max_framerate/mi,mdss-dsi-smart-fps-max_framerate/g' ${dts_source}/dsi-panel*
sed -i 's/\/\/ qcom,mdss-dsi-pan-enable-smart-fps/qcom,mdss-dsi-pan-enable-smart-fps/g' ${dts_source}/dsi-panel*
sed -i 's/qcom,mdss-dsi-qsync-min-refresh-rate/\/\/qcom,mdss-dsi-qsync-min-refresh-rate/g' ${dts_source}/dsi-panel*

# Enable back refresh rates supported on MIUI
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-36-02-0c-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0a-dsc-video.dtsi
sed -i 's/120 90 60/120 90 60 50 30/g' ${dts_source}/dsi-panel-g7a-37-02-0b-dsc-video.dtsi
sed -i 's/144 120 90 60/144 120 90 60 50 48 30/g' ${dts_source}/dsi-panel-j3s-37-02-0a-dsc-video.dtsi

# Enable back brightness control from dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 03 FF/39 00 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 00 00 00 00 00 03 51 0D FF/39 00 00 00 00 00 03 51 0D FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 00 00 00 00 00 05 51 0F 8F 00 00/39 00 00 00 00 00 05 51 0F 8F 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 00 00/39 01 00 00 00 00 03 51 00 00/g' ${dts_source}/dsi-panel-j2-38-0c-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 03 FF/39 01 00 00 00 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j9-38-0a-0a-fhd-video.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 07 FF/39 01 00 00 00 00 03 51 07 FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j1u-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 03 51 0F FF/39 01 00 00 00 00 03 51 0F FF/g' ${dts_source}/dsi-panel-j2-p1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j1s-42-02-0a-mp-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-mp-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2-p2-1-42-02-0b-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 00 00 05 51 07 FF 00 00/39 01 00 00 00 00 05 51 07 FF 00 00/g' ${dts_source}/dsi-panel-j2s-mp-42-02-0a-dsc-cmd.dtsi
sed -i 's/\/\/39 01 00 00 01 00 03 51 03 FF/39 01 00 00 01 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j11-38-08-0a-fhd-cmd.dtsi
sed -i 's/\/\/39 01 00 00 11 00 03 51 03 FF/39 01 00 00 11 00 03 51 03 FF/g' ${dts_source}/dsi-panel-j2-p2-1-38-0c-0a-dsc-cmd.dtsi

make $MAKE_ARGS ${TARGET_DEVICE}_defconfig
echo "--- PitchKernel diagnostic: CONFIG_SCHED_WALT state after defconfig ---"
grep -E "^CONFIG_SCHED_WALT|^# CONFIG_SCHED_WALT" out/.config || echo "PitchKernel diagnostic: CONFIG_SCHED_WALT not present in out/.config at all"

if [ $KSU_ENABLE -eq 1 ]; then
  scripts/config --file out/.config \
    -e KSU \
    -e THREAD_INFO_IN_TASK \
    -e KSU_SUSFS \
    -e KSU_SUSFS_SUS_PATH \
    -e KSU_SUSFS_SUS_MOUNT \
    -e KSU_SUSFS_SUS_KSTAT \
    -e KSU_SUSFS_SPOOF_UNAME \
    -e KSU_SUSFS_ENABLE_LOG \
    -e KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS \
    -e KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG \
    -e KSU_SUSFS_OPEN_REDIRECT \
    -e KSU_SUSFS_SUS_MAP \
    -e KSU_MULTI_MANAGER_SUPPORT \
    -e KPM
else
  scripts/config --file out/.config -d KSU
fi

scripts/config --file out/.config \
  -e BBG

# --- TCP congestion control: build in BBR + switchable alternatives ---
# DEFAULT_TCP_CONG intentionally not set directly below: it's a Kconfig
# 'string' derived from the DEFAULT_BBR/DEFAULT_CUBIC/etc. choice block
# (see net/ipv4/Kconfig), not an independent setting. A previous attempt
# to explain this placed the comment INSIDE the backslash-continued
# scripts/config call below, which silently truncated the command at
# the first uncontinued comment line (no trailing backslash), causing
# 'build.sh: line NNN: -e: command not found' in CI. Comment moved
# above the command entirely so it can't break the continuation again.
scripts/config --file out/.config \
  -e TCP_CONG_ADVANCED \
  -e TCP_CONG_BBR \
  -e TCP_CONG_CUBIC \
  -e TCP_CONG_WESTWOOD \
  -e TCP_CONG_HTCP \
  -e TCP_CONG_BIC \
  -e DEFAULT_BBR \
  -d DEFAULT_CUBIC \
  -e NET_SCH_FQ \
  -e NET_SCH_FQ_CODEL
# --- end TCP congestion control ---

scripts/config --file out/.config \
  --set-str STATIC_USERMODEHELPER_PATH /system/bin/micd \
  -e PERF_CRITICAL_RT_TASK \
  -e SF_BINDER \
  -e OVERLAY_FS \
  -e MIGT \
  -e MIGT_ENERGY_MODEL \
  -e MIHW \
  -e PACKAGE_RUNTIME_INFO \
  -e BINDER_OPT \
  -e KPERFEVENTS \
  -e MILLET \
  -e PERF_HUMANTASK \
  -d LTO_CLANG \
  -e LTO_NONE \
  -e SF_BINDER \
  -e XIAOMI_MIUI \
  -d MI_MEMORY_SYSFS \
  -e TASK_DELAY_ACCT \
  -e MIUI_ZRAM_MEMORY_TRACKING \
  -e MI_FRAGMENTION \
  -e PERF_HELPER \
  -e BOOTUP_RECLAIM \
  -e MI_RECLAIM \
  -e RTMM \
  -d REKERNEL \
  -d REKERNEL_NETWORK

# See AOSP block above for why olddefconfig is required here.
make $MAKE_ARGS olddefconfig
echo "--- PitchKernel diagnostic: CONFIG_SCHED_WALT state after olddefconfig ---"
grep -E "^CONFIG_SCHED_WALT|^# CONFIG_SCHED_WALT" out/.config || echo "PitchKernel diagnostic: CONFIG_SCHED_WALT not present in out/.config at all"
grep -n "KSU_SUSFS" out/.config | head -5

make $MAKE_ARGS -j"$JOBS"

if [ -f "out/arch/arm64/boot/Image" ]; then
  echo "The file [out/arch/arm64/boot/Image] exists. MIUI Build successfully."
else
  echo "The file [out/arch/arm64/boot/Image] does not exist. Seems MIUI build failed."
  exit 1
fi

echo "Generating [out/arch/arm64/boot/dtb]......"
find out/arch/arm64/boot/dts -name '*.dtb' -exec cat {} + >out/arch/arm64/boot/dtb

# Restore modified dts
rm -rf ${dts_source}
mv .dts.bak ${dts_source}

rm -rf anykernel/kernels/
mkdir -p anykernel/kernels/miui/

# Patch for SukiSU KPM support.
if [ $KSU_ENABLE -eq 1 ]; then
  cd out/arch/arm64/boot/
  wget https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.13.0/patch_linux
  chmod +x patch_linux
  ./patch_linux
  rm Image
  mv oImage Image
  cd -
fi

cp out/arch/arm64/boot/Image anykernel/kernels/miui/
cp out/arch/arm64/boot/dtb anykernel/kernels/miui/
cp out/arch/arm64/boot/dtbo.img anykernel/kernels/miui/
echo "Build for MIUI finished."
# ------------- End of Building for MIUI -------------
# If you don't need MIUI you can comment out the above block [Building for MIUI]

cd anykernel
ZIP_FILENAME=PitchKernel_MIUI_${TARGET_DEVICE}_${KSU_ZIP_STR}_$(date +'%Y%m%d_%H%M%S')_anykernel3_${GIT_COMMIT_ID}.zip
zip -r9 $ZIP_FILENAME ./* -x .git .gitignore out/ ./*.zip
mv $ZIP_FILENAME ../
cd ..

echo "Done. The flashable zip is: [./$ZIP_FILENAME]"
