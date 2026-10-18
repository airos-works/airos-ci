#!/usr/bin/env bash
# Cubie A7S release inputs: PowerVR/Zink, libglvnd, firmware and U-Boot.
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
if [[ ${AIROS_LOCKED:-} != haiku-arm64 ]]; then
	exec env AIROS_LOCKED=haiku-arm64 flock "$AIROS_LOCKS/haiku-arm64.lock" "$0" "$@"
fi
export AIROS_ARCH=arm64
. "$AIROS_CI/lib/sdk.sh"
"$AIROS_CI/sdk/build-cubie-host.sh"
. "$AIROS_TOOLCHAIN/cubie-host/env.sh"
W=$AIROS_WORK/cubie
INPUTS=$AIROS_ROOT/image-inputs/cubie
BOARD=$HAIKU_SOURCE/tools/cubie-a7s
GL=$AIROS_ROOT/gl/arm64/boot/system
[[ -f $GL/lib/libGL.so.1 ]] || "$AIROS_CI/deps/build-gl.sh"
mkdir -p "$W/base/sysroot" "$INPUTS"/{lib,egl,demos,firmware,boot}

note "Cubie graphics sysroot"
# Use this image's SDK, with only the common GL headers/libraries overlaid.
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
note "PowerVR Vulkan and Zink OpenGL"
CUBIE_MESA_ROOT=$W/mesa CUBIE_MESA_BASE=$W/base CUBIE_CROSS_PREFIX=${CROSS%-} \
	CUBIE_NATIVE_DEPS=${CUBIE_NATIVE_DEPS:-/} HAIKU_WORK_ROOT=$AIROS_ROOT HAIKU_JOBS=$JOBS \
	"$BOARD/mesa/build.sh" all
for name in libGL.so* libEGL.so* libGLESv2.so* libOpenGL.so* libGLdispatch.so* libGLU.so*; do
	cp -a "$GL/lib/"$name "$INPUTS/lib/"
done
cp "$W/mesa/out/"{libEGL_mesa.so.0,libvulkan_powervr_mesa.so,libvulkan.so.1} "$INPUTS/lib/"
cp "$W/mesa/out/10_mesa.json" "$INPUTS/egl/"
cp "$AIROS_ROOT/image-inputs/arm64/demos/GLTeapot" "$INPUTS/demos/"

note "Cubie firmware"
"$BOARD/fetch-gpu-firmware.sh" "$INPUTS/firmware/powervr"
version=5.0+git20260123.5f7be68d-5
deb=$AIROS_CACHE/aic8800-firmware-$version.deb
sha=14f200ef0ed4be63a52b05028b2d6e28701ccbf9404a60afc4f519119ee6605d
mkdir -p "$AIROS_CACHE"
if [[ ! -f $deb ]]; then
	curl -fLsS --retry 3 -o "$deb.part" \
		"https://github.com/radxa-pkg/aic8800/releases/download/$version/aic8800-firmware_${version}_all.deb"
	mv "$deb.part" "$deb"
fi
echo "$sha  $deb" | sha256sum -c --quiet
rm -rf "$W/firmware"
dpkg-deb -x "$deb" "$W/firmware"
source=$W/firmware/lib/firmware/aic8800_fw/USB/aic8800D80
dest=$INPUTS/firmware/aic8800wifi
mkdir -p "$dest"
for file in fw_patch_table_8800d80_u02.bin fw_adid_8800d80_u02.bin \
	fw_patch_8800d80_u02.bin fw_patch_8800d80_u02_ext0.bin \
	fmacfw_8800d80_u02.bin fmacfw_8800d80_h_u02.bin aic_userconfig_8800d80.txt; do
	cp "$source/$file" "$dest/"
done
# Preserve the distributor's actual notices, without substituting lab metadata.
cp "$W/firmware/usr/share/doc/aic8800-firmware/copyright" "$dest/COPYRIGHT.radxa"
cp /usr/share/common-licenses/GPL-2 /usr/share/common-licenses/GPL-3 "$dest/"
printf 'Radxa aic8800-firmware %s\nDebian package SHA-256 %s\n' "$version" "$sha" > "$dest/PROVENANCE"

note "Cubie U-Boot"
UBOOT_SRC=$W/u-boot-src UBOOT_BUILD=$W/u-boot-build \
	"$BOARD/u-boot/build.sh" "$INPUTS/boot/u-boot.bin"
"$BOARD/fetch-bootloader.sh" "$INPUTS/boot"
{
	echo "haiku $HAIKU_SHA"
	echo "uboot_base $(git -C "$W/u-boot-src" rev-parse HEAD^)"
	echo "uboot_patch $(sha256sum "$BOARD/u-boot/0001-sunxi-chainload.patch" | cut -d' ' -f1)"
	echo "aic8800_firmware $version $sha"
	echo "cross_compiler $("${CROSS}gcc" --version | head -n 1)"
	echo "uboot_compiler $(${CROSS_COMPILE:-aarch64-linux-gnu-}gcc --version | head -n 1)"
	echo "uboot_host_tools $(cat "$AIROS_TOOLCHAIN/cubie-host/key")"
	echo "llvm_host $(llvm-config-18 --version)"
	# Preserve each Mesa manifest line under a unique key.
	awk '{ print "mesa_" NR, $0 }' "$W/mesa/out/MANIFEST"
	cat "$AIROS_ROOT/image-inputs/arm64/gl-sources.txt"
} > "$INPUTS/cubie-sources.txt"
note "Cubie inputs ready: $INPUTS"
