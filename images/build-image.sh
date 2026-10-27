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

# The applications every image carries (Summit is the default browser; Snap
# is in the Deskbar menu's Demos folder), and the ones built here at the pins
# in apps/office.lock.json and media.lock.json for the Office and Media folders.
IMAGE_APPS=(summit summit_webkit amp airtime kiri airshot burrow snap)
PINNED_SETS=(office media)
[[ $TARGET != rpi4 ]] || IMAGE_APPS+=(rpi_installer)
# AirPins, the GPIO tool of the boards' pin headers
[[ $TARGET != rpi4 && $TARGET != cubie ]] || IMAGE_APPS+=(airpins)
# Aurora needs Node.js: HaikuPorts' nodejs22 on x86_64 (below), airos-ci's
# (deps/recipes/nodejs22.sh, in the pool) on arm64. Proton Mail Bridge links
# HaikuPorts' Qt on x86_64 and carries its own on arm64. Mail replaces Haiku's
# (the tree leaves Haiku's Mail out of x86_64 and arm64 images); arm64 images
# get it below, once the tree is known.
IMAGE_APPS+=(aurora)
# AirTop (system monitor), and Code - OSS and GitHub Desktop on Aurora (on
# x86_64 they require HaikuPorts' ripgrep and git, which come in with the
# requires below; arm64 images get git from deps/recipes/git.sh, below).
IMAGE_APPS+=(airtop code_oss github_desktop)
PINNED_SETS+=(bridge)
if [[ $TARGET == x86_64 ]]; then
	PINNED_SETS+=(mail)
else
	IMAGE_APPS+=(nodejs22)
fi
# Every one of them is required: stop now, before the long builds, rather than
# publish an image without an application.
missing=()
for app in "${IMAGE_APPS[@]}"; do
	compgen -G "$AIROS_PACKAGES/$ARCH/$app-[0-9]*-$ARCH.hpkg" > /dev/null || missing+=("$app")
done
[[ ${#missing[@]} -eq 0 ]] || die "not in the package pool $AIROS_PACKAGES/$ARCH: ${missing[*]}"
# Proton VPN, in every image (x86_64 and arm64 builds are in the pool); the
# copy below stops the image if it is missing.
IMAGE_APPS+=(proton_vpn)

# 1. Haiku at REF: the SDK build updates the worktree and the build directory
#    of the architecture and builds haiku.hpkg and the host tools.
build_stage "Haiku and the SDK"
"$AIROS_CI/sdk/build-sdk.sh" "$ARCH" "$REF"
. "$AIROS_SDK/$ARCH/env.sh"
# arm64 (ROCK 5, Pi, Cubie): Mail, with the base ICU and the Summit engine's
# libraries (apps/build-app-packages.sh mail_arm64_deps), where the tree leaves
# Haiku's Mail out of arm64 images; an older tree's would be a second apps/Mail.
if [[ $ARCH == arm64 ]] && grep -qF '$(TARGET_ARCH) = arm64 {' \
		"$HAIKU_SOURCE/build/jam/images/definitions/regular"; then
	PINNED_SETS+=(mail)
fi

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
	# and NVK (Vulkan on nvidia_rm) and the Zink OpenGL renderer on it, against
	# this Haiku revision (deps/build-nvk.sh, build-zink.sh; their build trees
	# are kept, so ninja rebuilds only what the new headers or pins change)
	build_stage "NVK" "Vulkan for NVIDIA"
	"$AIROS_CI/deps/build-nvk.sh"
	build_stage "Zink" "OpenGL on Vulkan for NVIDIA"
	"$AIROS_CI/deps/build-zink.sh"
fi
# arm64: libpng and FreeType for the system, which Haiku's arm64 repository
# has not (libpng) or only as the bootstrap FreeType 2.6.3
# (deps/recipes/libpng.sh, freetype.sh, under this build's lock; nothing to do
# while the fork pins and the recipes stay the same).
if [[ $ARCH == arm64 ]]; then
	build_stage "libpng and FreeType" "deps/recipes/libpng.sh, freetype.sh"
	"$AIROS_CI/deps/build-deps.sh" arm64 libpng freetype
	# and OpenSSH (ssh, sshd) with its libedit, and git with nano (its
	# editor; GitHub Desktop and Code - OSS need git), which x86_64 has from
	# HaikuPorts; under HaikuPorts' names (deps/recipes/libedit.sh,
	# openssh.sh, nano.sh, git.sh)
	build_stage "OpenSSH and git" "deps/recipes/libedit.sh, openssh.sh, nano.sh, git.sh"
	"$AIROS_CI/deps/build-deps.sh" arm64 libedit openssh nano git
	# and ICU 74 and ncurses in place of the repository's bootstrap builds,
	# whose libicuuc, libicui18n, libicuio and libncurses++w carry private
	# copies of the unwinder (a C++ exception through them ended the program)
	build_stage "ICU and ncurses" "deps/recipes/icu74.sh, ncurses6.sh"
	"$AIROS_CI/deps/build-deps.sh" arm64 icu74 ncurses6
fi
# ROCK 5 and Pi: the GL stack (Panfrost; V3D and V3DV) against this Haiku
# revision, which also refuses a Mali CSF ABI that differs from the tree's
# driver (deps/build-gl.sh; incremental like NVK). The Cubie's comes from
# deps/build-cubie.sh below.
if [[ $TARGET == arm64 || $TARGET == rpi4 ]]; then
	build_stage "GL stack" "Mesa Panfrost, V3D and V3DV, libglvnd, GLU"
	"$AIROS_CI/deps/build-gl.sh"
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
# HaikuPorts packages for jam to install (AIROS_CI_SYSTEM_PACKAGES)
system_packages=()
for app in "${IMAGE_APPS[@]}"; do
	file=$(ls "$pool/$app"-[0-9]*-"$ARCH".hpkg 2>/dev/null | head -n 1 || true)
	[[ -n $file ]] || die "$app left the package pool during the build"
	cp "$file" "$WORK/packages/"
done
# Office and Media are part of every release image: build-pinned.sh stops the
# image (and verify-pinned.sh checks it again) instead of silently publishing
# one without a requested application.
for set in "${PINNED_SETS[@]}"; do
	build_stage "${set^}" "$(json "$AIROS_CI/apps/$set.lock.json" \
		'", ".join(e["binary"] for e in d.values() if "binary" in e)')"
	"$AIROS_CI/apps/build-pinned.sh" "$set" "$ARCH" "$WORK/packages"
	"$AIROS_CI/images/verify-pinned.sh" "$TOOLS/package/package" "$ARCH" "$WORK/packages" "$set"
done
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
	# (x264, x265, SVT-AV1); and the color emoji font Terminal draws emoji
	# with (noto_emoji_color).
	AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" fetch --no-deps \
		x86_64 taglib2 scintilla lexilla lzo lz4 llvm21_libs vulkan \
		libelf wayland wayland_server libffi \
		intel_wifi_firmwares ralink_wifi_firmwares realtek_wifi_firmwares \
		x264 x265 svt_av13 noto_emoji_color | xargs -r cp -t "$WORK/packages/"
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
	# The color emoji font Terminal draws emoji with, recompressed the same
	# way; nothing requires it, so it goes in with the other packages.
	emoji_source=$(AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK \
		"$AIROS_CI/deps/haikuports.py" fetch --no-deps x86_64 noto_emoji_color)
	[[ -f $emoji_source && $emoji_source == *-any.hpkg ]] \
		|| die "expected one architecture-neutral noto_emoji_color package"
	"$package_tool" recompress -q -z zlib "$emoji_source" \
		"$WORK/packages/$(basename "$emoji_source")"
	# FreeType (above) as HAIKU_ARM64_FREETYPE_PACKAGES_DIR: the tree's
	# BuildFeatures compiles Haiku against freetype_devel and its Jamfile puts
	# the freetype package in the image instead of the bootstrap one.
	for name in freetype freetype_devel; do
		file=$(ls "$pool/$name"-[0-9]*-arm64.hpkg 2>/dev/null | head -n 1 || true)
		[[ -n $file ]] || die "no $name package in $pool (deps/recipes/freetype.sh)"
		cp "$file" "$WORK/freetype/"
	done
	# OpenSSH, libedit, nano and git (above): x86_64 images have them from
	# HaikuPorts, and every arm64 image must have ssh and git too.
	for name in libedit openssh nano git; do
		file=$(ls "$pool/$name"-[0-9]*-arm64.hpkg 2>/dev/null | head -n 1 || true)
		[[ -n $file ]] || die "no $name package in $pool (deps/recipes/$name.sh)"
		cp "$file" "$WORK/packages/"
	done
	# ICU 74 and ncurses (above), which the tree's UserBuildConfig puts in
	# the image instead of the repository's (an older tree would carry both).
	if grep -qF AIROS_CI_BASE_PACKAGES "$HAIKU_SOURCE/tools/airos/ci/UserBuildConfig"; then
		for name in icu74 ncurses6; do
			file=$(ls "$pool/$name"-[0-9]*-arm64.hpkg 2>/dev/null | head -n 1 || true)
			[[ -n $file ]] || die "no $name package in $pool (deps/recipes/$name.sh)"
			cp "$file" "$WORK/packages/"
		done
	fi
	# Zstandard: the zstd build feature (lib/env.sh zstd_build_feature, the
	# same for the SDK's build) has haiku require libzstd, the zstd package.
	zstd_build_feature "$ARCH" "$BUILD" "$HAIKU_SOURCE"
	if [[ -n ${HAIKU_ARM64_ZSTD_PACKAGES_DIR:-} ]]; then
		cp "$HAIKU_ARM64_ZSTD_PACKAGES_DIR"/zstd-[0-9]*-arm64.hpkg "$WORK/packages/"
	fi
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
# arm64 EFI: the Dragon Q8B's GPU user land (deps/build-dragon.sh), once the
# tree has its build
dragon=
if [[ $TARGET == arm64 && -x $HAIKU_SOURCE/tools/dragon-q8b/mesa/build.sh ]]; then
	build_stage "Dragon inputs" "Turnip, zink and the Adreno firmware"
	"$AIROS_CI/deps/build-dragon.sh"
	dragon=1
fi
# GL stack, EGL vendor files, demos, firmware and add-ons staged by the deps
# builds.
gl=$AIROS_ROOT/image-inputs/$TARGET
[[ -d $gl/lib ]] && cp -a "$gl/lib/." "$WORK/libs/"
[[ -d $gl/egl ]] && cp -a "$gl/egl/." "$WORK/egl/"
[[ -d $gl/demos ]] && cp -a "$gl/demos/." "$WORK/demos/"
[[ -d $gl/firmware ]] && cp -a "$gl/firmware/." "$WORK/firmware/"
# arm64: Terminal's OpenGL renderer, built with the GL stack
[[ -d $gl/add-ons ]] && cp -a "$gl/add-ons/." "$WORK/add-ons/"
# x86_64: nvidia_rm, its accelerant, NVDEC and NVENC (deps/build-nvidia.sh), NVK
# (deps/build-nvk.sh), the Zink renderer (deps/build-zink.sh), libvpx
# (deps/build-libvpx.sh): each a tree with lib/ and add-ons/
for part in "$gl"/nvidia "$gl"/nvk "$gl"/zink "$gl"/libvpx; do
	[[ -d $part/lib ]] && cp -a "$part/lib/." "$WORK/libs/"
	[[ -d $part/add-ons ]] && cp -a "$part/add-ons/." "$WORK/add-ons/"
done
# arm64: the Dragon's user land for system/non-packaged/adreno, which the boot
# script links into place only where the adreno driver publishes the GPU
[[ -z $dragon ]] || cp -a "$gl/adreno" "$WORK/adreno"
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
	# What the packages above require that none of them provides, from
	# HaikuPorts (haikuports.py skips what the base has): summit_webkit
	# links libxslt, woff2 and libexecinfo from the system, mupdf needs GLib,
	# Aurora needs cmd:node, which is nodejs22, the version its runtime is
	# tested with. As for Qt, jam installs the packages its HaikuPorts list
	# has (with their dependencies); the others go in as files.
	requires=$(python3 - "$TOOLS/package/package" "$WORK/packages" "$AIROS_CI/deps" <<'PY'
import glob, os, re, subprocess, sys
tool, directory, deps = sys.argv[1:4]
sys.path.insert(0, deps)
from haikuports import satisfies
provides, requires = [], []
for f in sorted(glob.glob(os.path.join(directory, "*.hpkg"))):
    out = subprocess.run([tool, "list", "-i", f], check=True, stdout=subprocess.PIPE, text=True).stdout
    provides += re.findall(r"(?m)^\s*provides:\s*(.*)$", out)
    requires += re.findall(r"(?m)^\s*requires:\s*(.*)$", out)
print("\n".join(sorted({r for r in requires if not any(satisfies(p, r) for p in provides)})))
PY
)
	files=$(AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK \
		"$AIROS_CI/deps/haikuports.py" fetch x86_64 nodejs22 $requires) \
		|| die "HaikuPorts cannot provide what the image's packages require"
	for file in $files; do
		name=$(basename "$file")
		name=${name%%-[0-9]*}
		if grep -qE "^[[:space:]]*$name-[0-9]" "$jamlist"; then
			system_packages+=("$name")
		elif [[ ! -e $WORK/packages/$(basename "$file") ]]; then
			cp "$file" "$WORK/packages/"
		fi
	done
	echo "HaikuPorts packages jam installs: ${system_packages[*]}"
	compgen -G "$WORK/packages/nodejs22-[0-9]*-x86_64.hpkg" > /dev/null \
		|| die "no nodejs22 package for Aurora"
fi
rpi_firmware=$gl/rpi-firmware
ls -1 "$WORK/packages" "$WORK/fonts" "$WORK/freetype" "$WORK/libpng" "$WORK/mupdf"

# The release: its id is the image directory's name, and a tree that knows
# System Updater (docs/airos/SYSTEM-UPDATER.md) makes the image a release it
# can update: the airos_release package names it, and the files CI puts
# outside packages go into the airos_payload package, linked from
# system/non-packaged (images/release-inputs.py). Each file of CI's trees is
# then named to jam, as AIROS_CI_FILES.
stamp=$(date -u +%Y%m%d-%H%M)-$HAIKU_REVISION
release=
if grep -q "^rule AirosMoveToPayload" "$HAIKU_SOURCE/tools/airos/ci/UserBuildConfig"; then
	release=$WORK/release-inputs
	python3 "$AIROS_CI/images/release-inputs.py" "$release" --id "$stamp" \
		--target "$TARGET" --arch "$ARCH" \
		--feed "${AIROS_UPDATE_FEED_BASE:-http://192.168.1.200/updates}/$TARGET/" \
		--haiku-revision "$HAIKU_REVISION" --haiku-commit "$HAIKU_SHA" \
		--recipe-commit "$(git -C "$AIROS_CI" rev-parse HEAD 2>/dev/null || echo unknown)" \
		--tree "system non-packaged lib=$WORK/libs" \
		--tree "system non-packaged add-ons opengl egl_vendor.d=$WORK/egl" \
		--tree "system non-packaged demos=$WORK/demos" \
		--tree "system non-packaged add-ons=$WORK/add-ons" \
		--tree "system non-packaged data firmware=$WORK/firmware" \
		--tree "system non-packaged amdgpu=$WORK/amdgpu" \
		--tree "system non-packaged adreno=$WORK/adreno"
fi

# 3. + 4. The image.
mkdir -p "$BUILD"
cd "$BUILD"
if [[ $TARGET == rpi4 || $TARGET == cubie ]] && { [[ ! -f build/BuildConfig ]] \
		|| ! grep -q "^#c $HAIKU_SOURCE/configure" build/BuildConfig; }; then
	"$HAIKU_SOURCE/configure" --distro-compatibility compatible --no-full-xattr \
		--cross-tools-prefix "$CROSS"
fi
# The Pi's code is tuned for its Cortex-A72 (SetCPUProfile in
# tools/airos/ci/UserBuildConfig, build/jam/ArchitectureRules). Objects keep
# the flags they were compiled with, and jam does not build them again when
# the flags change: a changed profile or OPTIM builds the Pi's objects anew.
if [[ $TARGET == rpi4 ]]; then
	flags=$( { sed -n '/^rule SetCPUProfile/,/^}/p' "$HAIKU_SOURCE/build/jam/ArchitectureRules"
		grep -E 'SetCPUProfile|OPTIM' "$HAIKU_SOURCE/tools/airos/ci/UserBuildConfig" || true
	} | sha256sum | cut -c1-16)
	if [[ -d objects && $(cat cpu-profile.key 2>/dev/null) != "$flags" ]]; then
		note "code generation flags changed: the $TARGET objects are built again"
		rm -rf objects
	fi
	echo "$flags" > cpu-profile.key
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
	[[ ! -d $WORK/adreno ]] || echo "AIROS_CI_ADRENO = $WORK/adreno ;"
	if [[ -n $release ]]; then
		echo "AIROS_CI_FILES = $release/files.jam ;"
		echo "AIROS_CI_RELEASE_VERSION = $(json "$release/release" 'd["version"]') ;"
		echo "AIROS_CI_RELEASE_DIR = $release ;"
	fi
	# one per line: jam refuses long lines
	if [[ ${#system_packages[@]} -gt 0 ]]; then
		echo "AIROS_CI_SYSTEM_PACKAGES ="
		printf '\t%s\n' "${system_packages[@]}" | sort -u
		echo ";"
	fi
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
dest=$AIROS_ARTIFACTS/images/$TARGET/$stamp
mkdir -p "$dest"
size=$(stat -c %s "$BUILD/$IMAGE")
xz -T0 -6 -c "$BUILD/$IMAGE" > "$dest/$IMAGE.xz"
( cd "$dest" && sha256sum "$IMAGE.xz" > "$IMAGE.xz.sha256" )
image_sha=$(sha256sum "$BUILD/$IMAGE" | cut -d' ' -f1)
# The airos-ci revision that made the image: its fork pins, Office and Media
# pins and recipes; "modified" when the checkout had uncommitted changes.
AIROS_CI_COMMIT=$(git -C "$AIROS_CI" rev-parse HEAD 2>/dev/null || echo unknown) \
AIROS_CI_MODIFIED=$(git -C "$AIROS_CI" status --porcelain --untracked-files=no 2>/dev/null | head -c1) \
AIROS_FORKS_LOCK_SHA=$(sha256sum "$AIROS_CI/forks/forks.lock.json" | cut -d' ' -f1) \
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
    "media": json.load(open(os.path.join(pkgdir, "media-sources.json"))),
    "bridge": json.load(open(os.path.join(pkgdir, "bridge-sources.json"))) if os.path.exists(os.path.join(pkgdir, "bridge-sources.json")) else None,
    "mail": json.load(open(os.path.join(pkgdir, "mail-sources.json"))) if os.path.exists(os.path.join(pkgdir, "mail-sources.json")) else None,
    "recipe": {"repository": "https://github.com/jmgasper/airos-ci",
               "commit": os.environ["AIROS_CI_COMMIT"],
               "modified": bool(os.environ["AIROS_CI_MODIFIED"]),
               "forks_lock_sha256": os.environ["AIROS_FORKS_LOCK_SHA"]},
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
# The release's packages for System Updater's feed, from the image itself
# (images/release-feed.py; published once the smoke test passed). bfs_shell
# mounts the image to read it, so only after its checksum above.
if [[ -n $release ]]; then
	build_stage "publish" "the release's packages for System Updater"
	boot_files=()
	if [[ $TARGET == rpi4 ]]; then
		boot_files+=(--boot-file "$BUILD/airos-boot.tgz")
		boot_files+=(--boot-file "$(find "$BUILD/objects/haiku/arm64" -name haiku_loader.rpi \
			-path '*/release/*' | head -n 1)=airos-loader.img")
	fi
	python3 "$AIROS_CI/images/release-feed.py" extract "$BUILD/$IMAGE" "$dest/release" \
		--tools "$BUILD/objects/linux/x86_64/release/tools" \
		--haiku-source "$HAIKU_SOURCE" "${boot_files[@]}"
fi
ln -sfn "$stamp" "$AIROS_ARTIFACTS/images/$TARGET/latest"
# Keep the last five images of each target.
ls -1dt "$AIROS_ARTIFACTS/images/$TARGET"/2* | tail -n +6 | xargs -r rm -rf
echo "image: $dest/$IMAGE.xz ($(du -h "$dest/$IMAGE.xz" | cut -f1); $((size / 1048576)) MiB uncompressed)"
echo "IMAGE_DIR=$dest" >> "${GITHUB_OUTPUT:-/dev/null}"
[[ -z $BUILD_ID ]] || python3 "$AIROS_CI/lib/status.py" end "$BUILD_ID" built "image_dir=$dest" \
	"haiku=$HAIKU_REVISION" "image=$IMAGE.xz" "stamp=$stamp" || true
