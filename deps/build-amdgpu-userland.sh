#!/usr/bin/env bash
# build-amdgpu-userland.sh
#
# The GPU user land of amdgpu_drm for the x86_64 images, cross-built from the
# forks as linux-drm's haiku/tools/gpu-userland-build.sh builds it natively
# on the X399 (with GPU_PREFIX=/boot/system/non-packaged,
# MESA_PLATFORMS=haiku,wayland, MESA_VULKAN_DRIVERS=amd and
# MESA_GALLIUM_VA=enabled):
#
#   libdrm, libdrm_amdgpu   jmgasper/libdrm airos-2.4.134
#   libva, libva-drm        jmgasper/libva airos-2.24.1
#   libglvnd                jmgasper/libglvnd airos-1.7.0 (libGL with the
#                           Haiku GL kit, libEGL, libGLESv2, libOpenGL)
#   Mesa                    jmgasper/mesa airos-amdgpu: radeonsi (OpenGL,
#                           GLES, EGL; llvmpipe and softpipe besides), RADV
#                           (Vulkan, with Wayland windows through Haiku's
#                           in-process Wayland server) and the VA-API driver
#   FFmpeg (static)         jmgasper/ffmpeg airos-6.1.6, H.264 and HEVC with
#                           VA-API only, for the amdgpu_va media add-on
#
# All of them for /boot/system/non-packaged, where they find each other
# through their RPATH. Results in $AIROS_ROOT/gl/x86_64-amdgpu:
#
#   root/      the run-time files (lib, lib/dri, data/libdrm, the EGL vendor
#              and Vulkan ICD manifests in add-ons), as they go under
#              /boot/system/non-packaged; the x86_64 image ships them in
#              system/non-packaged/amdgpu and its boot script links them into
#              place only where amdgpu_drm drives a GPU, as every other
#              machine keeps the system's OpenGL (deps/build-amdgpu.sh)
#   addon/     what the amdgpu_va add-on is built against: the headers of
#              libva and FFmpeg, libva's libraries and FFmpeg's static ones
#   sources.txt, haikuports.json   what went in
#
# Nothing is rebuilt while the pinned commits, the HaikuPorts packages and
# this script stay the same. Runs in the sdk-deps workflow and before every
# x86_64 image build (images/build-image.sh, through deps/build-amdgpu.sh).
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
if [[ ${AIROS_LOCKED:-} != haiku-x86_64 ]]; then
	exec env AIROS_LOCKED=haiku-x86_64 flock "$AIROS_LOCKS/haiku-x86_64.lock" "$0" "$@"
fi
export AIROS_ARCH=x86_64
. "$AIROS_CI/lib/sdk.sh"
. "$AIROS_CI/lib/fork.sh"

W=$AIROS_WORK/amdgpu-userland
OUT=${AMDGPU_USERLAND_OUT:-$AIROS_ROOT/gl/x86_64-amdgpu}
PREFIX=/boot/system/non-packaged
mkdir -p "$W" "$OUT"
cd "$W"
# Haiku's runtime_loader implements only general-dynamic TLS (no TLSDESC).
TLS=-mtls-dialect=gnu
# libva and Mesa exchange error numbers with libdrm as Linux code does:
# positive ones (posix_error_mapper; libdrm's meson.build does the same).
POSITIVE=-DB_USE_POSITIVE_POSIX_ERRORS
RPATH=-Wl,-rpath,$PREFIX/lib
MAPPER="-lposix_error_mapper $RPATH"
HAIKUPORTS=(llvm21 llvm21_libs libelf libelf_devel wayland wayland_devel wayland_protocols libffi
	libffi_devel)

note "sources"
fork_checkout libdrm "$W/libdrm"; DRM_COMMIT=$FORK_COMMIT
fork_checkout libva "$W/libva"; VA_COMMIT=$FORK_COMMIT
fork_checkout libglvnd "$W/libglvnd"; GLVND_COMMIT=$FORK_COMMIT
fork_checkout mesa-amdgpu "$W/mesa"; MESA_COMMIT=$FORK_COMMIT
fork_checkout ffmpeg "$W/ffmpeg"; FFMPEG_COMMIT=$FORK_COMMIT

AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" fetch --no-deps x86_64 \
	"${HAIKUPORTS[@]}" | xargs -n1 basename > "$W/haikuports.txt"
key=$(cat "$0" "$W/haikuports.txt" <(printf '%s\n' "$DRM_COMMIT" "$VA_COMMIT" "$GLVND_COMMIT" \
	"$MESA_COMMIT" "$FFMPEG_COMMIT") | sha256sum | cut -c1-16)
if [[ ${FORCE:-0} != 1 && ${CLEAN:-0} != 1 && -f $OUT/key && $(cat "$OUT/key") == "$key" \
		&& -f $OUT/root/lib/libEGL_mesa.so.0 && -f $OUT/addon/lib/libavcodec.a ]]; then
	echo "AMD GPU user land unchanged ($key): $OUT"
	exit 0
fi

note "host wayland-scanner"
# Mesa's Wayland code is generated on the build machine, by a wayland-scanner
# of the same version as the Haiku libwayland-client (meson checks): built
# from the source of HaikuPorts' wayland 1.21.0~git (X547/wayland), once.
WAYLAND_REV=149e9d7e1bab3b66a93f92c19c8056db547dd066
WAYLAND_SHA256=c7cbbcdcedb2e89086351f6d03a79a561ad486c1471d598a3959643fe7f94348
scanner=$AIROS_CACHE/host/wayland-scanner-${WAYLAND_REV:0:12}
if [[ ! -x $scanner/bin/wayland-scanner ]]; then
	rm -rf "$W/wayland" "$scanner"
	mkdir -p "$W/wayland"
	curl -sfL --retry 3 -o "$W/wayland/wayland.tar.gz" \
		"https://github.com/X547/wayland/archive/$WAYLAND_REV.tar.gz"
	echo "$WAYLAND_SHA256  $W/wayland/wayland.tar.gz" | sha256sum -c --quiet \
		|| die "the wayland source does not match its SHA-256"
	tar -xzf "$W/wayland/wayland.tar.gz" -C "$W/wayland"
	meson setup "$W/wayland/build" "$W/wayland/wayland-$WAYLAND_REV" --prefix="$scanner" \
		-Dlibraries=false -Dscanner=true -Ddocumentation=false -Ddtd_validation=false \
		-Dtests=false > "$W/wayland/setup.log" 2>&1 \
		|| { tail -20 "$W/wayland/setup.log"; die "wayland-scanner configure failed"; }
	ninja -C "$W/wayland/build" install > "$W/wayland/build.log" 2>&1 \
		|| { tail -20 "$W/wayland/build.log"; die "wayland-scanner build failed"; }
fi
HOSTPC=$(dirname "$(find "$scanner" -name wayland-scanner.pc | head -n 1)")
grep -H "^Version" "$HOSTPC/wayland-scanner.pc"

note "sysroot: the SDK's and HaikuPorts' LLVM 21, libelf, Wayland"
GLROOT=$W/sysroot
system=$GLROOT/boot/system
rm -rf "$GLROOT"
mkdir -p "$GLROOT"
# (data/ssl/private is the runner's own and no build needs it)
rsync -a --exclude=/boot/system/data/ssl/private "$SYSROOT/" "$GLROOT/"
AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" stage --no-deps x86_64 \
	"$system" "${HAIKUPORTS[@]}" > /dev/null
cp "$system/.haikuports.json" "$W/haikuports.json"
# pkg-config files of packages name their package's mount point
# (/packages/<name>/.self) as the prefix; in the sysroot it is /boot/system
find "$system" -path '*/pkgconfig/*.pc' -type f \
	-exec sed -i 's|^prefix=/packages/[^/]*/\.self|prefix=/boot/system|' {} +
# absolute links inside the sysroot point into it
while IFS= read -r -d '' link; do
	target=$(readlink "$link")
	[[ $target == /boot/system/* ]] && ln -sfn "$(realpath -m --relative-to="$(dirname "$link")" "$GLROOT$target")" "$link"
done < <(find "$system" -type l -print0)
np=$GLROOT$PREFIX
mkdir -p "$np"

# llvm-config for the Haiku LLVM, which cannot run here: what Mesa's meson asks
# (as deps/build-gl-x86_64.sh makes it).
llvm_cmake=$system/lib/cmake/llvm/LLVMConfig.cmake
llvm_version=$(sed -n 's/^set(LLVM_PACKAGE_VERSION \(.*\))/\1/p' "$llvm_cmake")
[[ $llvm_version == 21.* ]] || die "HaikuPorts' llvm21 has LLVM $llvm_version"
components=$(sed -n '/^set(LLVM_AVAILABLE_LIBS/,/)/p' "$llvm_cmake" | tr ' ;\n' '\n\n\n' \
	| sed -n 's/^LLVM\([A-Za-z0-9]*\))\{0,1\}$/\1/p' | tr 'A-Z' 'a-z' | sort -u | tr '\n' ' ')
# and llvm-config's pseudo components: "all", the targets (radeonsi and RADV
# ask for amdgpu even with ACO), ...
targets=$(sed -n 's/^set(LLVM_TARGETS_TO_BUILD \(.*\))/\1/p' "$llvm_cmake" | tr ';' ' ')
[[ " $targets " == *" AMDGPU "* ]] || die "HaikuPorts' llvm21 has no AMDGPU target"
components+="$(echo "$targets" | tr 'A-Z' 'a-z') all all-targets engine native nativecodegen"
cat > "$W/llvm-config" <<EOF
#!/bin/sh
# llvm-config for HaikuPorts' LLVM $llvm_version in $system (made by build-amdgpu-userland.sh)
out=""
for arg; do
	case \$arg in
		--version) out="\$out $llvm_version" ;;
		--prefix) out="\$out $system" ;;
		--includedir) out="\$out $system/develop/headers" ;;
		--libdir) out="\$out $system/develop/lib" ;;
		--cppflags) out="\$out -I$system/develop/headers -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS" ;;
		--cflags) out="\$out -I$system/develop/headers -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS" ;;
		--cxxflags) out="\$out -I$system/develop/headers -std=c++17 -D__STDC_CONSTANT_MACROS -D__STDC_FORMAT_MACROS -D__STDC_LIMIT_MACROS" ;;
		--ldflags) out="\$out -L$system/develop/lib" ;;
		--libs) out="\$out -lLLVM-21" ;;
		--libfiles) out="\$out $system/develop/lib/libLLVM-21.so" ;;
		--system-libs) ;;
		--shared-mode) out="\$out shared" ;;
		--has-rtti) out="\$out YES" ;;
		--assertion-mode) out="\$out OFF" ;;
		--build-mode) out="\$out Release" ;;
		--targets-built) out="\$out $targets" ;;
		--components) out="\$out $components" ;;
		--link-shared|--link-static|-*) ;;
		*) ;;
	esac
done
echo \$out
EOF
chmod 755 "$W/llvm-config"

PCDIRS="$np/develop/lib/pkgconfig:$np/data/pkgconfig:$system/develop/lib/pkgconfig:$system/lib/pkgconfig:$system/data/pkgconfig"
pclist=$(IFS=:; for dir in $PCDIRS; do printf "'%s', " "$dir"; done)
cat > "$W/cross.ini" <<EOF
[binaries]
c = '${CROSS}gcc'
cpp = '${CROSS}g++'
ar = '${CROSS}ar'
strip = '${CROSS}strip'
pkg-config = '/usr/bin/pkg-config'
llvm-config = '$W/llvm-config'

[host_machine]
system = 'haiku'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
needs_exe_wrapper = true
sys_root = '$GLROOT'
pkg_config_libdir = [${pclist%, }]

EOF
cat > "$W/native.ini" <<EOF
[built-in options]
pkg_config_path = ['$HOSTPC']
EOF
# FFmpeg's configure: pkg-config of the sysroot. Meson: the cross file's
# pkg_config_libdir and sys_root for Haiku, the native file's
# pkg_config_path (wayland-scanner) for this machine.
cross() { env -u CC -u CXX -u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
	PKG_CONFIG_LIBDIR="$PCDIRS" PKG_CONFIG_SYSROOT_DIR="$GLROOT" PKG_CONFIG_PATH= "$@"; }
mcross() { env -u CC -u CXX -u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
	-u PKG_CONFIG_LIBDIR -u PKG_CONFIG_SYSROOT_DIR -u PKG_CONFIG_PATH "$@"; }

# meson_build NAME SOURCE CFLAGS LDFLAGS OPTION...: configure (afresh) with
# these compiler and linker flags besides the sysroot's, build and install
# into $W/install, and into the sysroot for what comes after it.
INSTALL=$W/install
rm -rf "$INSTALL"
meson_build() {
	local name=$1 source=$2
	local cflags="--sysroot=$GLROOT $TLS $3" ldflags="--sysroot=$GLROOT -specs=$UNWIND_SPECS $4"
	shift 4
	note "$name"
	rm -rf "$W/build-$name"
	mcross meson setup "$W/build-$name" "$source" --cross-file="$W/cross.ini" \
		--native-file="$W/native.ini" --prefix=$PREFIX --libdir=lib --datadir=data \
		--includedir=develop/headers --buildtype=release --wrap-mode=nofallback \
		-Dc_args="$cflags" -Dcpp_args="$cflags" -Dc_link_args="$ldflags" \
		-Dcpp_link_args="$ldflags" "$@" \
		> "$W/$name-configure.log" 2>&1 \
		|| { tail -40 "$W/$name-configure.log"; die "$name configure failed ($W/$name-configure.log)"; }
	mcross ninja -C "$W/build-$name" -j"$JOBS" > "$W/$name-build.log" 2>&1 \
		|| { grep -m5 -B2 -A12 -E 'error|Error' "$W/$name-build.log"; die "$name build failed ($W/$name-build.log)"; }
	DESTDIR=$INSTALL mcross meson install -C "$W/build-$name" --no-rebuild > /dev/null
	DESTDIR=$GLROOT mcross meson install -C "$W/build-$name" --no-rebuild > /dev/null
}

meson_build libdrm "$W/libdrm" "" "$RPATH" \
	-Damdgpu=enabled -Dradeon=disabled -Dintel=disabled -Dnouveau=disabled \
	-Dvmwgfx=disabled -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled \
	-Dtegra=disabled -Dvc4=disabled -Detnaviv=disabled -Dcairo-tests=disabled \
	-Dman-pages=disabled -Dvalgrind=disabled -Dinstall-test-programs=false -Dtests=false

meson_build libva "$W/libva" "$POSITIVE" "$MAPPER" \
	-Ddisable_drm=false -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=no -Dwith_win32=no

meson_build libglvnd "$W/libglvnd" "" "" -Dx11=disabled -Dglx=disabled -Dhgl=true \
	-Dgles1=false -Dgles2=true -Degl=true

meson_build mesa "$W/mesa" "$POSITIVE" "$MAPPER" \
	-Dplatforms=haiku,wayland -Degl=enabled -Dglvnd=enabled -Dglx=disabled \
	-Dgbm=disabled -Dopengl=true -Dgles1=disabled -Dgles2=enabled \
	-Dgallium-drivers=radeonsi,llvmpipe,softpipe -Dvulkan-drivers=amd \
	-Damd-use-llvm=false -Dllvm=enabled -Dshared-llvm=enabled \
	-Dgallium-va=enabled -Dvideo-codecs=all -Dgallium-rusticl=false \
	-Dshader-cache=enabled -Dxmlconfig=disabled -Dexpat=disabled \
	-Dzstd=disabled -Dzlib=enabled -Dvalgrind=disabled \
	-Dlibunwind=disabled -Dlmsensors=disabled -Dspirv-tools=disabled \
	-Dbuild-tests=false '-Dtools=[]'

note "FFmpeg (static, VA-API) for the amdgpu_va add-on"
ADDON=$W/addon
rm -rf "$W/build-ffmpeg" "$ADDON"
mkdir -p "$W/build-ffmpeg"
(cd "$W/build-ffmpeg" && cross "$W/ffmpeg/configure" --prefix="$ADDON" \
	--enable-cross-compile --target-os=haiku --arch=x86_64 --cross-prefix="$CROSS" \
	--sysroot="$GLROOT" --pkg-config=pkg-config --extra-cflags="$TLS" \
	--enable-static --disable-shared --enable-pic --disable-programs --disable-doc \
	--disable-avdevice --disable-avformat --disable-avfilter --disable-swresample \
	--disable-swscale --disable-network --disable-autodetect --disable-everything \
	--enable-decoder=h264,hevc --enable-parser=h264,hevc \
	--enable-hwaccel=h264_vaapi,hevc_vaapi --enable-vaapi > "$W/ffmpeg-configure.log" 2>&1) \
	|| { tail -30 "$W/ffmpeg-configure.log"; die "FFmpeg configure failed ($W/ffmpeg-configure.log)"; }
grep -q '^CONFIG_H264_VAAPI_HWACCEL=yes' "$W/build-ffmpeg/ffbuild/config.mak" \
	|| die "FFmpeg was configured without H.264 on VA-API"
cross make -C "$W/build-ffmpeg" -j"$JOBS" install > "$W/ffmpeg-build.log" 2>&1 \
	|| { grep -m5 -B2 -A12 -E 'error' "$W/ffmpeg-build.log"; die "FFmpeg build failed ($W/ffmpeg-build.log)"; }
# and libva for the add-on to link against
mkdir -p "$ADDON/lib" "$ADDON/include"
cp -a "$INSTALL$PREFIX/develop/headers/va" "$ADDON/include/"
cp -a "$INSTALL$PREFIX"/lib/libva.so* "$INSTALL$PREFIX"/lib/libva-drm.so* "$ADDON/lib/"

note "results"
root=$W/root
rm -rf "$root"
mkdir -p "$root/lib" "$root/data" "$root/add-ons/opengl/egl_vendor.d" "$root/add-ons/vulkan/icd.d"
cp -a "$INSTALL$PREFIX/lib/." "$root/lib/"
rm -rf "$root/lib/pkgconfig"
cp -a "$INSTALL$PREFIX/data/libdrm" "$root/data/"
# libglvnd looks for EGL vendors in add-ons/opengl/egl_vendor.d on Haiku, and
# the Vulkan loader for drivers in add-ons/vulkan/icd.d
cp "$INSTALL$PREFIX/data/glvnd/egl_vendor.d/50_mesa.json" "$root/add-ons/opengl/egl_vendor.d/"
cp "$INSTALL$PREFIX/data/vulkan/icd.d/radeon_icd.x86_64.json" "$root/add-ons/vulkan/icd.d/"
grep -q "\"$PREFIX/lib/libvulkan_radeon.so\"" "$root/add-ons/vulkan/icd.d/radeon_icd.x86_64.json" \
	|| die "RADV's manifest does not name $PREFIX/lib/libvulkan_radeon.so"
find "$root/lib" -type f -name '*.so*' -exec "${CROSS}strip" --strip-unneeded {} +
# Haiku's loader cannot do TLS descriptors or the initial-exec model in
# libraries it loads late.
if find "$root/lib" -type f -name '*.so*' -exec "${CROSS}readelf" -rW {} + 2>/dev/null \
		| grep -qE 'TLSDESC|R_X86_64_TPOFF'; then
	die "unsupported TLS relocations in the AMD GPU libraries"
fi
for lib in libGL.so.1 libEGL.so.1 libGLESv2.so.2 libEGL_mesa.so.0 libvulkan_radeon.so \
		libdrm.so.2 libdrm_amdgpu.so.1 libva.so.2 libva-drm.so.2 dri/radeonsi_drv_video.so; do
	[[ -e $root/lib/$lib ]] || die "no $lib"
done
printf 'libdrm %s\nlibva %s\nlibglvnd %s\nmesa %s\nffmpeg %s\nllvm %s\n' "$DRM_COMMIT" \
	"$VA_COMMIT" "$GLVND_COMMIT" "$MESA_COMMIT" "$FFMPEG_COMMIT" "$llvm_version" > "$W/sources.txt"
rsync -rlc --chmod=g+rwX --delete "$root/" "$OUT/root/"
rsync -rlc --chmod=g+rwX --delete "$ADDON/" "$OUT/addon/"
cp "$W/sources.txt" "$W/haikuports.json" "$OUT/"
echo "$key" > "$OUT/key"
du -sh "$OUT/root"
find "$OUT/root" \( -type f -o -type l \) | sed "s|$OUT/root/||" | sort
