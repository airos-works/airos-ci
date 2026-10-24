#!/usr/bin/env bash
# build-dragon.sh
#
# The Radxa Dragon Q8B's GPU user land for the arm64 EFI image, from the Haiku
# tree the image is built from:
#   tools/dragon-q8b/mesa/build.sh   Mesa 26.2.4 (archive.mesa3d.org, pinned
#                                    sha256): Turnip on the adreno driver,
#                                    zink's EGL vendor library (the Cubie's
#                                    OpenGL patch) and the libvulkan.so.1 shim
#   tools/dragon-q8b/fetch-gpu-firmware.sh
#                                    linux-firmware's a660 SQE/GMU microcode
#                                    and SC8280XP zap shader (pinned commit)
#
# Results:
#   $AIROS_ROOT/image-inputs/arm64/adreno   the tree the image carries as
#                       system/non-packaged/adreno (AIROS_CI_ADRENO); its boot
#                       script links it into system/non-packaged only where
#                       the adreno driver publishes the GPU, every other
#                       machine keeps the ROCK 5's Panfrost stack
#   $AIROS_ROOT/image-inputs/arm64/firmware/qcom   the GPU firmware, for the
#                       image's firmware tree (AIROS_CI_FIRMWARE): the driver
#                       needs it before the boot script runs
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
if [[ ${AIROS_LOCKED:-} != haiku-arm64 ]]; then
	exec env AIROS_LOCKED=haiku-arm64 flock "$AIROS_LOCKS/haiku-arm64.lock" "$0" "$@"
fi
export AIROS_ARCH=arm64
. "$AIROS_CI/lib/sdk.sh"
W=$AIROS_WORK/dragon
INPUTS=$AIROS_ROOT/image-inputs/arm64
BOARD=$HAIKU_SOURCE/tools/dragon-q8b
GL=$AIROS_ROOT/gl/arm64/boot/system
[[ -x $BOARD/mesa/build.sh ]] || die "$HAIKU_REVISION has no tools/dragon-q8b/mesa/build.sh"
[[ -f $GL/lib/libGL.so.1 ]] || "$AIROS_CI/deps/build-gl.sh"
mkdir -p "$W/base/sysroot" "$INPUTS"

note "Dragon graphics sysroot"
# As deps/build-cubie.sh: this image's SDK with the common GL headers and
# libraries (libglvnd) overlaid.
rsync -a --delete "$SYSROOT/" "$W/base/sysroot/"
rsync -a "$GL/" "$W/base/sysroot/boot/system/"
system=$W/base/sysroot/boot/system
while IFS= read -r -d '' link; do
	target=$(readlink "$link")
	[[ $target != /boot/system/* ]] || ln -sfn \
		"$(realpath -m --relative-to="$(dirname "$link")" "$W/base/sysroot$target")" "$link"
done < <(find "$system" -type l -print0)
cat > "$W/base/haiku-aarch64.ini" <<EOF
[binaries]
c = '${CROSS}gcc'
cpp = '${CROSS}g++'
ar = '${CROSS}ar'
strip = '${CROSS}strip'
pkg-config = '/usr/bin/pkg-config'
[host_machine]
system = 'haiku'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
[properties]
needs_exe_wrapper = true
sys_root = '$W/base/sysroot'
pkg_config_libdir = ['$system/develop/lib/pkgconfig', '$system/lib/pkgconfig']
[built-in options]
c_args = ['--sysroot=$W/base/sysroot']
cpp_args = ['--sysroot=$W/base/sysroot']
c_link_args = ['--sysroot=$W/base/sysroot']
cpp_link_args = ['--sysroot=$W/base/sysroot']
EOF

note "Dragon GPU firmware"
"$BOARD/fetch-gpu-firmware.sh" "$W/firmware"

note "Turnip Vulkan and zink OpenGL"
DRAGON_MESA_ROOT=$W/mesa CUBIE_MESA_BASE=$W/base CUBIE_CROSS_PREFIX=${CROSS%-} \
	HAIKU_WORK_ROOT=$AIROS_ROOT HAIKU_JOBS=$JOBS \
	"$BOARD/mesa/build.sh" all
for file in lib/libEGL_mesa.so.0 lib/libvulkan_freedreno.so lib/libvulkan.so.1 \
		add-ons/opengl/egl_vendor.d/05_mesa_adreno.json; do
	[[ -e $W/mesa/out/adreno/$file ]] || die "no $file in the Dragon user land"
done
rm -rf "$INPUTS/adreno"
cp -a "$W/mesa/out/adreno" "$INPUTS/adreno"
# the firmware as files of the image (the driver loads it when the GPU is
# first used, which can be before the boot script)
rm -rf "$INPUTS/firmware/qcom"
mkdir -p "$INPUTS/firmware/qcom/sc8280xp"
cp "$W/firmware/qcom/a660_sqe.fw" "$W/firmware/qcom/a660_gmu.bin" \
	"$W/firmware/LICENSE.qcom" "$W/firmware/NOTICE.qcom" "$INPUTS/firmware/qcom/"
cp "$W/firmware/qcom/sc8280xp/qcdxkmsuc8280.mbn" "$INPUTS/firmware/qcom/sc8280xp/"
{
	echo "haiku $HAIKU_SHA"
	echo "cross_compiler $("${CROSS}gcc" --version | head -n 1)"
	awk '{ print "mesa_" NR, $0 }' "$W/mesa/out/MANIFEST"
	awk '{ print "userland_" NR, $0 }' "$W/mesa/out/adreno.MANIFEST"
} > "$INPUTS/adreno-sources.txt"
note "Dragon inputs ready: $INPUTS/adreno"
