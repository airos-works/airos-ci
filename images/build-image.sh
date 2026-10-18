#!/usr/bin/env bash
# build-image.sh TARGET [REF]
#
# Build an air/OS release image from jmgasper/haiku at REF (default
# origin/master) with the tree's CI image definitions
# (tools/airos/ci/UserBuildConfig) and the packages in the air/OS package pool:
#
#   x86_64  airos-x86_64.iso   hybrid ISO (USB stick or CD), EFI and BIOS
#   arm64   airos-arm64.iso    hybrid ISO with an EFI system partition
#                              (ROCK 5 ITX and other UEFI arm64 machines)
#   rpi4    airos-rpi4.img     Raspberry Pi 4 SD card image, boots directly
#   cubie   airos-cubie.img    Radxa Cubie A7S SD card with its boot chain
#
# The image (xz-compressed, with SHA-256 sums and a manifest of everything that
# went in) is published to $AIROS_ARTIFACTS/images/TARGET/<stamp>/ and
# $AIROS_ARTIFACTS/images/TARGET/latest, which the build server serves over
# HTTP. The build is recorded for the build dashboard (lib/status.py,
# $AIROS_DATA/builds); CLEAN=1 builds Haiku from scratch. The x86_64 image also
# rebuilds the NVIDIA driver, accelerant and NVDEC, and the AMD driver
# amdgpu_drm with its firmware package, from the same Haiku tree.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"

TARGET=${1:?usage: build-image.sh x86_64|arm64|rpi4|cubie [ref]}
REF=${2:-origin/master}
case $TARGET in
	x86_64) ARCH=x86_64 PROFILE=nightly-airos-x86_64 JAM_TARGET= IMAGE=airos-x86_64.iso ;;
	arm64)  ARCH=arm64 PROFILE=airos-arm64 JAM_TARGET= IMAGE=airos-arm64.iso ;;
	rpi4)   ARCH=arm64 PROFILE=airos-rpi4 JAM_TARGET=airos-rpi-image IMAGE=airos-rpi4.img ;;
	cubie)  ARCH=arm64 PROFILE=airos-cubie JAM_TARGET= IMAGE=airos-cubie.img ;;
	*) die "unknown target $TARGET" ;;
esac
# The build's record for the build dashboard (lib/status.py): opened before the
# wait for the lock, unless whoever started the build opened it (BUILD_ID), and
# the output goes to its log as well.
# (A record that cannot be written never stops the build.)
if [[ -z ${BUILD_ID:-} ]]; then
	BUILD_ID=$(python3 "$AIROS_CI/lib/status.py" begin "$TARGET" --ref "$REF" \
		${CLEAN:+--clean} 2>/dev/null) || BUILD_ID=
	export BUILD_ID
fi
if [[ -n $BUILD_ID && -z ${BUILD_LOGGING:-} ]]; then
	export BUILD_LOGGING=1
	exec > >(tee -a "$AIROS_DATA/builds/$BUILD_ID/log.txt") 2>&1
	python3 "$AIROS_CI/lib/status.py" set "$BUILD_ID" "pid=$$" || true
fi

# The whole build holds the architecture's lock: it updates the SDK's worktree
# and build directory (the Pi build shares the arm64 worktree and compiler).
if [[ ${AIROS_LOCKED:-} != haiku-$ARCH ]]; then
	build_stage "waiting for the build server" "another $ARCH build or job holds the $ARCH tree"
	exec env AIROS_LOCKED=haiku-$ARCH flock "$AIROS_LOCKS/haiku-$ARCH.lock" "$0" "$@"
fi
trap 'status=$?; [[ $status == 0 || -z $BUILD_ID ]] \
	|| python3 "$AIROS_CI/lib/status.py" end "$BUILD_ID" failed "exit=$status"' EXIT

# CLEAN=1: a build from scratch: the Haiku objects of the architecture (and the
# Pi's) go first, so jam builds everything again (cross tools are kept).
if [[ ${CLEAN:-0} == 1 ]]; then
	build_stage "cleaning" "removing the $ARCH build objects"
	rm -rf "$AIROS_BUILD/haiku-$ARCH/objects" "$AIROS_BUILD/haiku-$ARCH/generated"
	[[ $TARGET == x86_64 || $TARGET == arm64 ]] || rm -rf "$AIROS_BUILD/haiku-$TARGET/objects" "$AIROS_BUILD/haiku-$TARGET/generated"
fi

# The applications every image carries (Summit is the default browser).
OFFICE_APPS=(clipper wordcraft gridcraft deckcraft pdfcraft)
IMAGE_APPS=(summit summit_webkit amp airtime kiri airshot turbochook burrow)
[[ $TARGET != rpi4 ]] || IMAGE_APPS+=(rpi_installer)
# Aurora (Electron apps) runs on Node.js, which only x86_64 has.
[[ $TARGET != x86_64 ]] || IMAGE_APPS+=(aurora)

# 1. Haiku at REF: the SDK build updates the worktree and the build directory
#    of the architecture and builds haiku.hpkg and the host tools.
build_stage "Haiku and the SDK"
"$AIROS_CI/sdk/build-sdk.sh" "$ARCH" "$REF"
. "$AIROS_SDK/$ARCH/env.sh"

# x86_64: the NVIDIA driver, its accelerant and the NVDEC add-on are not built
# by jam; build them from this same Haiku revision (deps/build-nvidia.sh, under
# this build's lock; about 20 s when little changed).
if [[ $TARGET == x86_64 ]]; then
	build_stage "NVIDIA driver" "nvidia_rm, accelerant, NVDEC"
	"$AIROS_CI/deps/build-nvidia.sh"
	# and the AMD driver, amdgpu_drm, and its firmware: packages for
	# system/packages (deps/build-amdgpu.sh; the accelerant is in haiku.hpkg)
	build_stage "AMD driver" "amdgpu_drm, amdgpu firmware"
	"$AIROS_CI/deps/build-amdgpu.sh"
	# and Qt: HaikuPorts' qt6_base with air/OS's Haiku platform plugin, which
	# draws at the desktop's density (deps/build-qt-airos.sh)
	build_stage "Qt" "qt6_base with the air/OS platform plugin"
	"$AIROS_CI/deps/build-qt-airos.sh"
	# and libvpx with x86-64 code and VP9's high bit depth, ahead of
	# HaikuPorts' generic build (deps/build-libvpx.sh; once per version)
	build_stage "libvpx" "VP8/VP9 with SIMD and 10-bit VP9"
	"$AIROS_CI/deps/build-libvpx.sh"
fi
# arm64: libpng and FreeType for the system, which Haiku's arm64 repository
# has not (libpng) or only as the bootstrap FreeType 2.6.3
# (deps/recipes/libpng.sh, freetype.sh, under this build's lock; nothing to do
# while the fork pins and the recipes stay the same).
if [[ $ARCH == arm64 ]]; then
	build_stage "libpng and FreeType" "deps/recipes/libpng.sh, freetype.sh"
	"$AIROS_CI/deps/build-deps.sh" arm64 libpng freetype
fi

BUILD=$HAIKU_BUILD
if [[ $TARGET == rpi4 || $TARGET == cubie ]]; then
	# Its own build directory (its own UserBuildConfig) with the arm64 compiler.
	BUILD=$AIROS_BUILD/haiku-$TARGET
fi

WORK=$AIROS_WORK/image-$TARGET
rm -rf "$WORK"
mkdir -p "$WORK"/{packages,fonts,freetype,libpng,ffmpeg,mupdf,libs,egl,demos,firmware,add-ons}

# 2. The inputs.
note "inputs"
build_stage "inputs" "packages, GL stacks, firmware"
pool=$AIROS_PACKAGES/$ARCH
any=$AIROS_PACKAGES/any
missing=()
# HaikuPorts packages for jam to install (AIROS_CI_SYSTEM_PACKAGES)
system_packages=()
for app in "${IMAGE_APPS[@]}"; do
	file=$(ls "$pool/$app"-[0-9]*-"$ARCH".hpkg 2>/dev/null | head -n 1 || true)
	if [[ -n $file ]]; then cp "$file" "$WORK/packages/"; else missing+=("$app"); fi
done
build_stage "Office" "Clipper, WordCraft, GridCraft, DeckCraft, PdfCraft"
"$AIROS_CI/apps/build-office.sh" "$ARCH" "$WORK/packages"
# Office is part of every release image. A missing build must stop the image
# instead of silently publishing one without a requested application.
for app in "${OFFICE_APPS[@]}"; do
	compgen -G "$WORK/packages/$app-[0-9]*-$ARCH.hpkg" > /dev/null \
		|| die "missing Office package $app for $ARCH; build it with apps/ci-build-app.sh"
done
"$AIROS_CI/images/verify-office.sh" "$TOOLS/package/package" "$ARCH" "$WORK/packages"
# Libraries and system components CI builds (airos_*, rock5_ffmpeg,
# wpa_supplicant, ...) and firmware: architecture-neutral packages, and on
# arm64 HaikuPorts' Wi-Fi firmware recompressed with zlib
# (deps/build-firmware.sh).
for file in "$pool"/airos_*-"$ARCH".hpkg "$pool"/rock5_*-"$ARCH".hpkg \
		"$pool"/wpa_supplicant-*-"$ARCH".hpkg "$pool"/*_wifi_firmwares-*-any.hpkg "$any"/*.hpkg; do
	[[ -e $file ]] && cp "$file" "$WORK/packages/"
done
if [[ $ARCH == x86_64 ]]; then
	# The applications' x86_64 requirements that the build system's HaikuPorts
	# list lacks (the others come with AddHaikuImageSystemPackages), and what
	# summit_webkit's private Mesa needs: LLVM 21 (llvmpipe) and the Vulkan
	# loader (zink); what the AMD GPU user land needs besides (libelf, and
	# Wayland with Haiku's in-process Wayland server for Vulkan windows); and
	# the Wi-Fi firmware Haiku's image leaves out (Intel cards such as the
	# X399's AX210, Ralink, Realtek); and the CPU video encoders
	# MediaConverter opens for H.264, H.265 and AV1 when no GPU can make them
	# (x264, x265, SVT-AV1).
	AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" fetch --no-deps \
		x86_64 taglib2 scintilla lexilla lzo lz4 llvm21_libs vulkan \
		libelf wayland wayland_server libffi \
		intel_wifi_firmwares ralink_wifi_firmwares realtek_wifi_firmwares \
		x264 x265 svt_av13 | xargs -r cp -t "$WORK/packages/"
	# MuPDF for Quick Look's document preview (HAIKU_MUPDF_PACKAGES_DIR: the
	# tree's BuildFeatures compiles the add-on against mupdf_devel), and mupdf
	# with its jbig2dec in the image; the build system's HaikuPorts list lacks
	# all three.
	for source in $(AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK \
			"$AIROS_CI/deps/haikuports.py" fetch --no-deps x86_64 mupdf mupdf_devel jbig2dec); do
		cp "$source" "$WORK/mupdf/"
		[[ $source == */mupdf_devel-* ]] || cp "$source" "$WORK/packages/"
	done
	[[ $(ls "$WORK/mupdf" | wc -l) == 3 ]] || die "expected the mupdf, mupdf_devel and jbig2dec packages"
	# Vision: HaikuPorts' build with its Deskbar entry in the menu's Utilities
	# folder, for a tree whose UserBuildConfig then keeps the repository's
	# Vision (in the nightly profile) out of the image.
	if grep -q "^rule SuppressHaikuImagePackages" "$HAIKU_SOURCE/build/jam/ImageRules"; then
		"$AIROS_CI/deps/deskbar-repack.sh" x86_64 vision Utilities "$WORK/packages" > /dev/null
	fi
else
	# curl and Summit use /boot/system/data/ssl/CARootCertificates.pem.
	# This package is architecture-neutral, but the repository copy may use
	# zstd, which the arm64 release package readers do not necessarily support.
	ca_source=$(AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK \
		"$AIROS_CI/deps/haikuports.py" fetch --no-deps x86_64 ca_root_certificates)
	[[ -f $ca_source && $ca_source == *-any.hpkg ]] \
		|| die "expected one architecture-neutral CA certificate package"
	package_tool=$HAIKU_BUILD/objects/linux/x86_64/release/tools/package/package
	# The architecture-neutral pool may already contain an older bundle.
	rm -f "$WORK/packages/"ca_root_certificates-*-any.hpkg
	"$package_tool" recompress -q -z zlib "$ca_source" \
		"$WORK/packages/$(basename "$ca_source")"
	# The system fonts. app_server defaults to Noto Sans and, for the fixed
	# font, Noto Sans Mono; x86_64 images carry HaikuPorts' noto and the CJK
	# fallback noto_sans_cjk_jp. The arm64 repository has only the bootstrap
	# noto (2017, without Noto Sans Mono), with which the fixed font falls back
	# to a proportional serif. Recompressed like the CA bundle, they go in as
	# system packages of their own (AIROS_CI_FONTS): they satisfy the haiku
	# package's noto requirement, so jam leaves the bootstrap noto out.
	for source in $(AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK \
			"$AIROS_CI/deps/haikuports.py" fetch --no-deps x86_64 noto noto_sans_cjk_jp); do
		[[ $source == *-any.hpkg ]] || die "$source is not architecture-neutral"
		"$package_tool" recompress -q -z zlib "$source" "$WORK/fonts/$(basename "$source")"
	done
	[[ $(ls "$WORK/fonts" | wc -l) == 2 ]] || die "expected the noto and noto_sans_cjk_jp packages"
	# FreeType (above) as HAIKU_ARM64_FREETYPE_PACKAGES_DIR: the tree's
	# BuildFeatures compiles Haiku against freetype_devel and its Jamfile puts
	# the freetype package in the image instead of the bootstrap one.
	for name in freetype freetype_devel; do
		file=$(ls "$pool/$name"-[0-9]*-arm64.hpkg 2>/dev/null | head -n 1 || true)
		[[ -n $file ]] || die "no $name package in $pool (deps/recipes/freetype.sh)"
		cp "$file" "$WORK/freetype/"
	done
	# libpng (above) as HAIKU_ARM64_LIBPNG_PACKAGES_DIR: Haiku's libpng build
	# feature (the PNG translator) and the libpng16 package in the image.
	for name in libpng16 libpng16_devel; do
		file=$(ls "$pool/$name"-[0-9]*-arm64.hpkg 2>/dev/null | head -n 1 || true)
		[[ -n $file ]] || die "no $name package in $pool (deps/recipes/libpng.sh)"
		cp "$file" "$WORK/libpng/"
	done
	# FFmpeg as HAIKU_ARM64_FFMPEG_PACKAGES_DIR: Haiku's ffmpeg build feature,
	# for MediaConverter (rock5_ffmpeg itself goes in with the pool's rock5_*
	# packages; its devel package is kept apart, deps/recipes/rock5_ffmpeg.sh).
	base=$(ls "$pool"/rock5_ffmpeg-[0-9]*-arm64.hpkg 2>/dev/null | head -n 1 || true)
	devel=$(ls "$AIROS_ROOT"/image-inputs/arm64/ffmpeg-devel/rock5_ffmpeg_devel-[0-9]*-arm64.hpkg \
		2>/dev/null | head -n 1 || true)
	if [[ -n $base && -n $devel ]]; then
		cp "$base" "$devel" "$WORK/ffmpeg/"
	else
		echo "warning: no rock5_ffmpeg_devel (deps/build-deps.sh arm64 rock5_ffmpeg): no MediaConverter" >&2
	fi
fi
if [[ $TARGET == cubie ]]; then
	build_stage "Cubie inputs" "PowerVR graphics, firmware and U-Boot"
	"$AIROS_CI/deps/build-cubie.sh"
fi
# GL stack, EGL vendor files, demos, firmware and add-ons staged by the deps
# builds.
gl=$AIROS_ROOT/image-inputs/$TARGET
[[ -d $gl/lib ]] && cp -a "$gl/lib/." "$WORK/libs/"
[[ -d $gl/egl ]] && cp -a "$gl/egl/." "$WORK/egl/"
[[ -d $gl/demos ]] && cp -a "$gl/demos/." "$WORK/demos/"
[[ -d $gl/firmware ]] && cp -a "$gl/firmware/." "$WORK/firmware/"
# x86_64: nvidia_rm, its accelerant, NVDEC and NVENC (deps/build-nvidia.sh), NVK
# (deps/build-nvk.sh), the Zink renderer (deps/build-zink.sh), libvpx
# (deps/build-libvpx.sh): each a tree with lib/ and add-ons/
for part in "$gl"/nvidia "$gl"/nvk "$gl"/zink "$gl"/libvpx; do
	[[ -d $part/lib ]] && cp -a "$part/lib/." "$WORK/libs/"
	[[ -d $part/add-ons ]] && cp -a "$part/add-ons/." "$WORK/add-ons/"
done
# x86_64: amdgpu_drm and amdgpu_firmwares, and the AMD GPU user land for
# system/non-packaged/amdgpu (deps/build-amdgpu.sh), which every x86_64 image
# carries
if [[ $ARCH == x86_64 ]]; then
	for name in amdgpu_drm amdgpu_firmwares; do
		ls "$gl/amdgpu/packages/$name"-[0-9]*.hpkg > /dev/null 2>&1 \
			|| die "no $name package in $gl/amdgpu/packages (deps/build-amdgpu.sh)"
	done
	cp "$gl"/amdgpu/packages/*.hpkg "$WORK/packages/"
	for file in lib/libEGL_mesa.so.0 lib/libvulkan_radeon.so lib/wayland-server-inproc.so \
			add-ons/media/plugins/amduvd; do
		[[ -e $gl/amdgpu/userland/$file ]] \
			|| die "no $file in $gl/amdgpu/userland (deps/build-amdgpu.sh)"
	done
	cp -a "$gl/amdgpu/userland" "$WORK/amdgpu"
	# The in-process Wayland server built with the user land, for every
	# machine: in system/non-packaged/lib it comes before HaikuPorts'
	# wayland_server, so GTK, Firefox and Vulkan windows get the desktop's
	# scale on NVIDIA and other PCs too (on AMD ones the boot script leaves
	# this copy alone, the user land's is the same file).
	cp "$gl/amdgpu/userland/lib/wayland-server-inproc.so" "$WORK/libs/"
	# Qt (deps/build-qt-airos.sh): the patched qt6_base goes in as a file, so
	# Qt programs installed later (Telegram from HaikuDepot) use it; of what it
	# needs, jam installs the packages its HaikuPorts list has
	# (AIROS_CI_SYSTEM_PACKAGES, with their dependencies), the others go in as
	# files too.
	qt=$AIROS_ROOT/qt/x86_64/packages
	ls "$qt"/qt6_base-[0-9]*.hpkg > /dev/null 2>&1 \
		|| die "no qt6_base package in $qt (deps/build-qt-airos.sh)"
	jamlist=$HAIKU_SOURCE/build/jam/repositories/HaikuPorts/$ARCH
	for file in "$qt"/*.hpkg; do
		name=$(basename "$file")
		name=${name%%-[0-9]*}
		if [[ $name != qt6_base ]] && grep -qE "^[[:space:]]*$name-[0-9]" "$jamlist"; then
			system_packages+=("$name")
		else
			cp "$file" "$WORK/packages/"
		fi
	done
	# Node.js for Aurora (cmd:node): HaikuPorts' nodejs22, the version
	# Aurora's runtime is tested with. Of what it needs, jam installs the
	# packages its HaikuPorts list has, the others (libuv, c-ares) go in as
	# files, as for Qt.
	for file in $(AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK \
			"$AIROS_CI/deps/haikuports.py" fetch x86_64 nodejs22); do
		name=$(basename "$file")
		name=${name%%-[0-9]*}
		if grep -qE "^[[:space:]]*$name-[0-9]" "$jamlist"; then
			system_packages+=("$name")
		else
			cp "$file" "$WORK/packages/"
		fi
	done
	compgen -G "$WORK/packages/nodejs22-[0-9]*-x86_64.hpkg" > /dev/null \
		|| die "no nodejs22 package for Aurora"
fi
rpi_firmware=$gl/rpi-firmware
ls -1 "$WORK/packages" "$WORK/fonts" "$WORK/freetype" "$WORK/libpng" "$WORK/mupdf"
[[ ${#missing[@]} -eq 0 ]] || echo "warning: not in the package pool yet: ${missing[*]}" >&2

# 3. + 4. The image.
mkdir -p "$BUILD"
cd "$BUILD"
if [[ $TARGET == rpi4 || $TARGET == cubie ]] && { [[ ! -f build/BuildConfig ]] \
		|| ! grep -q "^#c $HAIKU_SOURCE/configure" build/BuildConfig; }; then
	"$HAIKU_SOURCE/configure" --distro-compatibility compatible --no-full-xattr \
		--cross-tools-prefix "$CROSS"
fi
[[ -f $HAIKU_SOURCE/tools/airos/ci/UserBuildConfig ]] \
	|| die "$REF has no tools/airos/ci/UserBuildConfig"
{
	echo "# written by airos-ci images/build-image.sh"
	echo "AIROS_CI_PACKAGES = $WORK/packages ;"
	[[ -z $(ls "$WORK/fonts") ]] || echo "AIROS_CI_FONTS = $WORK/fonts ;"
	[[ -z $(ls "$WORK/freetype") ]] || echo "HAIKU_ARM64_FREETYPE_PACKAGES_DIR = $WORK/freetype ;"
	[[ -z $(ls "$WORK/libpng") ]] || echo "HAIKU_ARM64_LIBPNG_PACKAGES_DIR = $WORK/libpng ;"
	[[ -z $(ls "$WORK/ffmpeg") ]] || echo "HAIKU_ARM64_FFMPEG_PACKAGES_DIR = $WORK/ffmpeg ;"
	[[ -z $(ls "$WORK/mupdf") ]] || echo "HAIKU_MUPDF_PACKAGES_DIR = $WORK/mupdf ;"
	[[ -z $(ls "$WORK/libs") ]] || echo "AIROS_CI_LIBS = $WORK/libs ;"
	[[ -z $(ls "$WORK/egl") ]] || echo "AIROS_CI_EGL = $WORK/egl ;"
	[[ -z $(ls "$WORK/demos") ]] || echo "AIROS_CI_DEMOS = $WORK/demos ;"
	[[ -z $(ls "$WORK/firmware") ]] || echo "AIROS_CI_FIRMWARE = $WORK/firmware ;"
	[[ -z $(ls "$WORK/add-ons") ]] || echo "AIROS_CI_ADDONS = $WORK/add-ons ;"
	[[ ! -d $WORK/amdgpu ]] || echo "AIROS_CI_AMDGPU = $WORK/amdgpu ;"
	[[ ${#system_packages[@]} -eq 0 ]] \
		|| echo "AIROS_CI_SYSTEM_PACKAGES = ${system_packages[*]} ;"
	# arm64: FluidLite for the MIDI kit (deps/recipes/fluidlite.sh)
	deps=$AIROS_ROOT/deps/$ARCH/boot/system
	[[ $ARCH != arm64 || ! -f $deps/develop/lib/libfluidlite.a ]] || echo "AIROS_CI_FLUIDLITE = $deps ;"
	[[ $TARGET != rpi4 ]] || echo "HAIKU_RPI_FIRMWARE_DIR = $rpi_firmware ;"
	echo "include $HAIKU_SOURCE/tools/airos/ci/UserBuildConfig ;"
} > UserBuildConfig
rm -f "$BUILD/$IMAGE"
# The build's attribute emulation (libroot_build) keeps a symlink's attributes
# under attributes/symlink-<inode>, and nothing removes them when the link is
# deleted. $WORK is made anew for every image, so a staged symlink that gets
# the inode of an old one inherits its attributes - "Error getting info for
# attribute BEOS:TYPE" when the image copies the add-ons. Links staged here
# have no attributes of their own.
if [[ -d $BUILD/attributes ]]; then
	find "$WORK" -type l -printf '%i\n' | while read -r inode; do
		rm -rf "$BUILD/attributes/symlink-$inode"
	done
fi
note "jam @$PROFILE $JAM_TARGET"
build_stage "image" "jam @$PROFILE $JAM_TARGET"
jam -q -j"$JOBS" "@$PROFILE" $JAM_TARGET
if [[ $TARGET == cubie ]]; then
	jam -q -j"$JOBS" '<build>fat_shell' haiku_loader.efi
	CUBIE_BUILD=$BUILD CUBIE_BOOTLOADER_DIR=$gl/boot UBOOT_BIN=$gl/boot/u-boot.bin \
		"$HAIKU_SOURCE/tools/cubie-a7s/build-sd-image.sh" \
		"$BUILD/haiku-airos-cubie.image" "$BUILD/$IMAGE"
fi
[[ -f $BUILD/$IMAGE ]] || die "build made no $IMAGE"
# The SDK's build directory must not keep this UserBuildConfig.
[[ $TARGET == rpi4 || $TARGET == cubie ]] || rm -f "$BUILD/UserBuildConfig"

# 5. Publish.
note "publish"
build_stage "publish" "xz, checksums, manifest"
stamp=$(date -u +%Y%m%d-%H%M)-$HAIKU_REVISION
dest=$AIROS_ARTIFACTS/images/$TARGET/$stamp
mkdir -p "$dest"
size=$(stat -c %s "$BUILD/$IMAGE")
xz -T0 -6 -c "$BUILD/$IMAGE" > "$dest/$IMAGE.xz"
( cd "$dest" && sha256sum "$IMAGE.xz" > "$IMAGE.xz.sha256" )
image_sha=$(sha256sum "$BUILD/$IMAGE" | cut -d' ' -f1)
AIROS_BUILD_TOOLS_SHA=$(cat "$HAIKU_BUILD/cross-tools-$ARCH/.buildtools-revision") \
AIROS_CC_VERSION=$("${CROSS}gcc" -dumpfullversion) \
AIROS_IMAGE_RECIPE_SHA=$(sha256sum "$AIROS_CI/images/build-image.sh" | cut -d' ' -f1) \
python3 - "$dest/manifest.json" "$TARGET" "$IMAGE" "$size" "$image_sha" "$HAIKU_REVISION" \
	"$HAIKU_SHA" "$WORK/packages" "$gl" "$WORK/fonts" "$WORK/freetype" "$WORK/libpng" <<'EOF'
import glob, hashlib, json, os, sys, datetime
out, target, image, size, sha, rev, haiku_sha, pkgdir, inputs = sys.argv[1:10]
# The packages CI put in the image: AIROS_CI_PACKAGES, the fonts, FreeType and
# libpng (whose _devel packages only build Haiku).
pkgs = sorted((os.path.join(d, p) for d in [pkgdir] + sys.argv[10:] for p in os.listdir(d)
               if p.endswith(".hpkg") and "_devel-" not in p), key=os.path.basename)
# What the files outside packages were built from (the *-sources.txt the deps
# builds leave with them: GL stacks, NVIDIA, NVK, Zink).
sources = {}
for path in sorted(glob.glob(os.path.join(inputs, "*-sources.txt"))
                   + glob.glob(os.path.join(inputs, "*", "*-sources.txt"))):
    name = os.path.basename(path)[:-len("-sources.txt")]
    sources[name] = dict(line.split(" ", 1) for line in open(path).read().splitlines() if " " in line)
json.dump({
    "inputs": sources,
    "office": json.load(open(os.path.join(pkgdir, "office-sources.json"))),
    "toolchain": {"buildtools_commit": os.environ["AIROS_BUILD_TOOLS_SHA"],
                  "gcc": os.environ["AIROS_CC_VERSION"],
                  "image_recipe_sha256": os.environ["AIROS_IMAGE_RECIPE_SHA"]},
    "target": target, "image": image, "image_bytes": int(size), "image_sha256": sha,
    "built": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
    "haiku": {"repository": "https://github.com/jmgasper/haiku", "revision": rev, "commit": haiku_sha},
    "packages": [{"file": os.path.basename(p), "sha256": hashlib.sha256(open(p, "rb").read()).hexdigest()}
                 for p in pkgs],
}, open(out, "w"), indent=1)
EOF
ln -sfn "$stamp" "$AIROS_ARTIFACTS/images/$TARGET/latest"
# Keep the last five images of each target.
ls -1dt "$AIROS_ARTIFACTS/images/$TARGET"/2* | tail -n +6 | xargs -r rm -rf
echo "image: $dest/$IMAGE.xz ($(du -h "$dest/$IMAGE.xz" | cut -f1); $((size / 1048576)) MiB uncompressed)"
echo "IMAGE_DIR=$dest" >> "${GITHUB_OUTPUT:-/dev/null}"
[[ -z $BUILD_ID ]] || python3 "$AIROS_CI/lib/status.py" end "$BUILD_ID" built "image_dir=$dest" \
	"haiku=$HAIKU_REVISION" "image=$IMAGE.xz" "stamp=$stamp" || true
