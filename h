[1mdiff --git a/build.sh b/build.sh[m
[1mindex 93705802462e..b2e0ceacbde7 100755[m
[1m--- a/build.sh[m
[1m+++ b/build.sh[m
[36m@@ -140,12 +140,53 @@[m [mOBJCOPY=llvm-objcopy \[m
 OBJDUMP=llvm-objdump \[m
 STRIP=llvm-strip"[m
 [m
[32m+[m[32m# PitchKernel: DIAGNOSTIC. Two prior theories for "LLVM ERROR: IO failure[m
[32m+[m[32m# on output stream: Broken pipe" are now ruled out by direct evidence:[m
[32m+[m[32m#   - Full LTO codegen: ruled out twice over. (1) errors span the entire[m
[32m+[m[32m#     ~10k-line compile phase (first seen ~line 290, last ~line 9959-10100[m
[32m+[m[32m#     across multiple runs), not clustered at the single final LTO link,[m
[32m+[m[32m#     which only happens once at the very end. (2) More fundamentally:[m
[32m+[m[32m#     both build paths below (AOSP ~line 272, MIUI ~line 425) run[m
[32m+[m[32m#     `scripts/config -d LTO_CLANG -e LTO_NONE` immediately before their[m
[32m+[m[32m#     real `make` call, explicitly overriding munch_defconfig's[m
[32m+[m[32m#     CONFIG_LTO_CLANG=y. LTO was never actually enabled in any build this[m
[32m+[m[32m#     script has produced -- the original theory was chasing a subsystem[m
[32m+[m[32m#     that was off the whole time. Confirmed by grep across this file, not[m
[32m+[m[32m#     assumed.[m
[32m+[m[32m#   - ccache: run 79958527969 set PITCHKERNEL_NO_CCACHE=1 (see that flag's[m
[32m+[m[32m#     gate above -- confirmed engaged via the printed diagnostic line and[m
[32m+[m[32m#     clang resolving straight to $TOOLCHAIN_PATH, no masquerade). Error[m
[32m+[m[32m#     count went 304 -> 452 with ccache fully removed -- higher, not lower.[m
[32m+[m[32m#     Ruled out.[m
[32m+[m[32m# Remaining suspect implicated by the evidence: make -j$(nproc) itself.[m
[32m+[m[32m# 4 concurrent clang processes writing to one combined stdout/stderr[m
[32m+[m[32m# stream that GitHub Actions' runner captures and forwards is a plausible[m
[32m+[m[32m# mechanism regardless of what wraps clang (ccache or not) -- if the[m
[32m+[m[32m# runner's log-forwarding briefly can't keep up under 4-way concurrent[m
[32m+[m[32m# write load, a writer can see EPIPE, and clang's LLVM backend is[m
[32m+[m[32m# documented upstream (llvm-project#174173, #73014) to abort hard and[m
[32m+[m[32m# unrecoverably on any EPIPE on its output stream rather than retry/ignore.[m
[32m+[m[32m# PITCHKERNEL_SERIAL_BUILD=1 forces -j1 (no concurrent clang processes at[m
[32m+[m[32m# all) for this one diagnostic build. This will be dramatically slower --[m
[32m+[m[32m# do not leave this set for regular builds. If the count drops to 0 at[m
[32m+[m[32m# -j1, make-level parallelism vs GHA's log capture is confirmed as the[m
[32m+[m[32m# real mechanism. If it does NOT drop to 0 even fully serial, the[m
[32m+[m[32m# remaining explanation is something in this exact clang/lld build[m
[32m+[m[32m# (Neutron clang 23.0.0git -- a dev snapshot, not a stable release) itself,[m
[32m+[m[32m# independent of parallelism and ccache -- at that point the next step is[m
[32m+[m[32m# checking whether a stable clang release reproduces it.[m
[32m+[m[32mJOBS="$(nproc)"[m
[32m+[m[32mif [ "${PITCHKERNEL_SERIAL_BUILD:-0}" == "1" ]; then[m
[32m+[m[32m  JOBS=1[m
[32m+[m[32m  echo "PITCHKERNEL_SERIAL_BUILD=1 -- DIAGNOSTIC: forcing -j1 (fully serial build, no concurrent clang processes). This will be much slower than normal."[m
[32m+[m[32mfi[m
[32m+[m
 if [ "$1" == "j1" ]; then[m
   make $MAKE_ARGS -j1[m
   exit[m
 fi[m
 if [ "$1" == "continue" ]; then[m
[31m-  make $MAKE_ARGS -j$(nproc)[m
[32m+[m[32m  make $MAKE_ARGS -j"$JOBS"[m
   exit[m
 fi[m
 [m
[36m@@ -238,7 +279,7 @@[m [mscripts/config --file out/.config \[m
   -d LTO_CLANG \[m
   -e LTO_NONE[m
 [m
[31m-make $MAKE_ARGS -j$(nproc)[m
[32m+[m[32mmake $MAKE_ARGS -j"$JOBS"[m
 [m
 if [ -f "out/arch/arm64/boot/Image" ]; then[m
   echo "The file [out/arch/arm64/boot/Image] exists. AOSP Build successfully."[m
[36m@@ -404,7 +445,7 @@[m [mscripts/config --file out/.config \[m
   -d REKERNEL \[m
   -d REKERNEL_NETWORK[m
 [m
[31m-make $MAKE_ARGS -j$(nproc)[m
[32m+[m[32mmake $MAKE_ARGS -j"$JOBS"[m
 [m
 if [ -f "out/arch/arm64/boot/Image" ]; then[m
   echo "The file [out/arch/arm64/boot/Image] exists. MIUI Build successfully."[m
