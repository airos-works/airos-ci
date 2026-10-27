#!/usr/bin/env bash
# build-amdgpu.sh
#
# The AMD graphics driver of the x86_64 images: amdgpu_drm, Linux 6.18's
# amdgpu with the DRM core, TTM, the GPU scheduler and Display Core, running
# on Haiku through a Linux compatibility layer, and the firmware it loads.
# Two packages, made by linux-drm's haiku/tools/package.sh:
#
#   amdgpu_drm-<linux>~git<date>-1-x86_64.hpkg   the driver (airos-works/linux-drm,
#                                 a release build), linked against the kernel
#                                 of the x86_64 SDK's Haiku build; it requires
#                                 that build's haiku package and the firmware
#   amdgpu_firmwares-<date>-<rev>-any.hpkg
#                                 every amdgpu file of linux-firmware
#                                 (airos-works/airos-firmware), Southern Islands
#                                 to RDNA 4 and the APUs
#
# into $AIROS_ROOT/image-inputs/x86_64/amdgpu/packages, which the x86_64 image
# puts in system/packages. app_server's side, the amdgpu_kms accelerant, is in
# haiku.hpkg. The driver binds to AMD GPUs only, and leaves Southern and Sea
# Islands GPUs to radeon_hd.
#
# And the GPU user land, in $AIROS_ROOT/image-inputs/x86_64/amdgpu/userland:
# libdrm, libva, libglvnd and Mesa (radeonsi, RADV, the VA-API driver) from
# deps/build-amdgpu-userland.sh, and the amdgpu_va media add-on (H.264 and HEVC
# on the GPU through VA-API; installed as "amduvd", the name airTime and Summit
# load AMD decoders by), built here from the Haiku tree. The image ships the
# tree in system/non-packaged/amdgpu; its boot script links it into
# system/non-packaged only where amdgpu_drm drives a GPU (Haiku's
# tools/airos/ci/boot/UserBootscript).
#
# images/build-image.sh x86_64 runs this with every image build, so the
# driver and the add-on match the image's Haiku revision; the sdk-deps
# workflow runs it too.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
if [[ ${AIROS_LOCKED:-} != haiku-x86_64 ]]; then
	exec env AIROS_LOCKED=haiku-x86_64 flock "$AIROS_LOCKS/haiku-x86_64.lock" "$0" "$@"
fi
export AIROS_ARCH=x86_64
. "$AIROS_CI/lib/sdk.sh"
. "$AIROS_CI/lib/fork.sh"

# The linux-firmware release airos-works/airos-firmware took the amdgpu
# directory from (forks/forks.json), and the firmware package's revision.
FIRMWARE_VERSION=20260916
FIRMWARE_REVISION=1

W=$AIROS_WORK/amdgpu
# (AMDGPU_INPUTS and AMDGPU_USERLAND_OUT: elsewhere, for trial runs)
INPUTS=${AMDGPU_INPUTS:-$AIROS_ROOT/image-inputs/x86_64}
mkdir -p "$W" "$INPUTS"
cd "$W"

note "sources"
fork_checkout linux-drm "$W/linux-drm"; DRM_COMMIT=$FORK_COMMIT
fork_checkout airos-firmware "$W/airos-firmware"; FW_COMMIT=$FORK_COMMIT
package=$W/linux-drm/haiku/tools/package.sh
[[ -x $package ]] || die "linux-drm ${DRM_COMMIT:0:12} has no haiku/tools/package.sh"
grep -q FIRMWARE_VERSION "$package" || die "linux-drm ${DRM_COMMIT:0:12}'s package.sh takes no FIRMWARE_VERSION"
[[ -d $W/airos-firmware/amdgpu && -f $W/airos-firmware/LICENSES/LICENSE.amdgpu ]] \
	|| die "airos-firmware ${FW_COMMIT:0:12} has no amdgpu firmware"

# package.sh takes the driver from out-release (a release build: no lab
# arming). The objects stay between builds (the checkout is kept while its
# commit is); the add-on is linked again every time, against this kernel.
OUT=$W/linux-drm/out-release
[[ ${CLEAN:-0} != 1 ]] || rm -rf "$OUT"
rm -f "$OUT/amdgpu_drm"
note "amdgpu_drm"
make -C "$W/linux-drm" -f haiku/build/Makefile -j"$JOBS" all OUT="$OUT" \
	HAIKU_TOP="$HAIKU_SOURCE" HAIKU_BUILD="$HAIKU_BUILD" CROSS="$CROSS" > "$W/build.log" 2>&1 \
	|| { grep -m5 -B2 -A8 -E "error|Error" "$W/build.log"; die "amdgpu_drm build failed ($W/build.log)"; }
ls -l "$OUT/amdgpu_drm"

note "packages"
rm -rf "$W/stage"
mkdir -p "$W/stage/packages"
HAIKU_BUILD=$HAIKU_BUILD FIRMWARE_VERSION=$FIRMWARE_VERSION FIRMWARE_REVISION=$FIRMWARE_REVISION \
	"$package" "$W/stage/packages" "$W/airos-firmware" "$W/airos-firmware/LICENSES/LICENSE.amdgpu"
for name in amdgpu_drm amdgpu_firmwares; do
	[[ $(ls "$W/stage/packages/$name"-[0-9]*.hpkg 2>/dev/null | wc -l) == 1 ]] \
		|| die "package.sh made no single $name package"
done

note "GPU user land"
"$AIROS_CI/deps/build-amdgpu-userland.sh"
USERLAND=${AMDGPU_USERLAND_OUT:-$AIROS_ROOT/gl/x86_64-amdgpu}

note "amdgpu_va (amduvd)"
# as docs/x399-workstation/tools/build-amdgpu-va-plugin.sh builds it on the
# X399: FFmpeg's decoders linked in statically (the system's FFmpeg has no
# VA-API), libva from system/non-packaged/lib
va=$HAIKU_SOURCE/src/add-ons/media/plugins/amdgpu_va
[[ -f $va/AmdgpuVaPlugin.cpp ]] || die "$HAIKU_REVISION has no amdgpu_va add-on"
addon=$W/amdgpu_va
rm -rf "$addon"
mkdir -p "$addon"
for source in AmdgpuVaPlugin H264Output HevcOutput; do
	"${CROSS}g++" --sysroot="$SYSROOT" -O2 -Wall -fPIC -I"$USERLAND/addon/include" \
		-I"$HAIKU_SOURCE/headers/private/media" -c "$va/$source.cpp" -o "$addon/$source.o"
done
"${CROSS}g++" --sysroot="$SYSROOT" -specs="$UNWIND_SPECS" -shared -o "$addon/amduvd" \
	"$addon"/*.o -Wl,--exclude-libs,ALL "$USERLAND/addon/lib/libavcodec.a" \
	"$USERLAND/addon/lib/libavutil.a" -L"$USERLAND/addon/lib" -lva -lva-drm -lbe -lmedia \
	-Wl,-rpath-link,"$USERLAND/root/lib" -Wl,-rpath,/boot/system/non-packaged/lib
"${CROSS}strip" --strip-unneeded "$addon/amduvd"
ls -l "$addon/amduvd"

note "image inputs"
mkdir -p "$W/stage/userland"
cp -a "$USERLAND/root/." "$W/stage/userland/"
mkdir -p "$W/stage/userland/add-ons/media/plugins"
cp "$addon/amduvd" "$W/stage/userland/add-ons/media/plugins/"
# what went in
{
	printf 'haiku %s\nlinux-drm %s\nairos-firmware %s\nlinux-firmware %s\n' "$HAIKU_REVISION" \
		"$DRM_COMMIT" "$FW_COMMIT" "$FIRMWARE_VERSION"
	cat "$USERLAND/sources.txt"
} > "$W/stage/amdgpu-sources.txt"
mkdir -p "$INPUTS/amdgpu"
rsync -rlc --delete "$W/stage/" "$INPUTS/amdgpu/"
ls -l "$INPUTS/amdgpu/packages"
du -sh "$INPUTS/amdgpu/userland"
