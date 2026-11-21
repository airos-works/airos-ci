#!/usr/bin/env bash
# build-amdgpu-userland.sh
#
# The GPU user land of amdgpu_drm, nouveau_drm and i915_drm for the x86_64
# images, cross-built from the
# forks as linux-drm's haiku/tools/gpu-userland-build.sh builds it natively
# on the X399 (with GPU_PREFIX=/boot/system/non-packaged,
# MESA_PLATFORMS=haiku,wayland, MESA_VULKAN_DRIVERS=amd and
# MESA_GALLIUM_VA=enabled):
#
#   libdrm, libdrm_amdgpu,  airos-works/libdrm airos-2.4.134 (airos-intel:
#   libdrm_nouveau,         libdrm_intel without libpciaccess, its CPU maps
#   libdrm_intel            through DRM_HAIKU_IOCTL_MAP)
#   libva, libva-drm        airos-works/libva airos-2.24.1
#   libglvnd                airos-works/libglvnd airos-1.7.0 (libGL with the
#                           Haiku GL kit, libEGL, libGLESv2, libOpenGL)
#   Mesa                    airos-works/mesa airos-amdgpu (airos-intel):
#                           radeonsi, nouveau and iris (OpenGL, GLES, EGL;
#                           llvmpipe and softpipe besides), RADV, NVK and ANV
#                           (Vulkan, with Wayland windows through Haiku's
#                           in-process Wayland server) and the VA-API driver
#                           of radeonsi and nouveau. The Gallium driver
#                           follows the DRM driver of the GPU (amdgpu_drm,
#                           nouveau_drm or i915_drm). NVK, which needs
#                           Rust for Haiku (sdk/build-rust.sh) and Mesa's CL
#                           compilers built for this machine, is renamed
#                           libvulkan_nouveau_drm.so, apart from the image's
#                           NVK on nvidia_rm (deps/build-nvk.sh), which has
#                           Mesa's name
#   intel-vaapi-driver      airos-works/intel-vaapi-driver airos: i965, the
#                           VA-API driver of Intel GPUs up to Comet Lake on
#                           i915_drm (decoding and encoding; libva takes it
#                           for "i915" after iHD, which is not built)
#   FFmpeg (static)         airos-works/ffmpeg airos-6.1.6, H.264, HEVC, VP9 and
#                           AV1 with VA-API only, for the amdgpu_va media add-on
#   in-process Wayland      airos-works/wayland-server airos: X547's server with
#   server                  the desktop's scale for GTK, Firefox and Vulkan
#                           windows; ahead of HaikuPorts' wayland_server in
#                           the library path where it is linked into place
#
# All of them for /boot/system/non-packaged, where they find each other
# through their RPATH. Results in $AIROS_ROOT/gl/x86_64-amdgpu:
#
#   root/      the run-time files (lib, lib/dri, data/libdrm, the EGL vendor
#              and Vulkan ICD manifests in add-ons), as they go under
#              /boot/system/non-packaged; the x86_64 image ships them in
#              system/non-packaged/amdgpu and its boot script links them into
#              place only where amdgpu_drm or nouveau_drm drives a GPU, as every other
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
fork_checkout intel-vaapi-driver "$W/intel-vaapi-driver"; I965_COMMIT=$FORK_COMMIT
fork_checkout ffmpeg "$W/ffmpeg"; FFMPEG_COMMIT=$FORK_COMMIT
fork_checkout wayland-server "$W/wayland-server"; WLS_COMMIT=$FORK_COMMIT

# Direct present on AMD GPUs (Summit, jmgasper/haiku#37) takes both forks:
# RADV asks amdgpu_drm for the screen's frame buffer (VkImportScanoutMemoryHAIKU)
# and imports the handle it gets as a KMS handle, which only libdrm's Haiku
# amdgpu_bo_import() takes (eec11b92). A RADV with the first half and a libdrm
# without the second build and run, but every present fails (-3) and Summit
# copies its frames through app_server: the images of October 2026 shipped
# that way, the libdrm pin left on 2310822c. Checked before the cache, so a
# user land built from such a pair is not reused either.
if grep -q 'amdgpu_bo_handle_type_kms, scanout.handle' \
		"$W/mesa/src/amd/vulkan/winsys/amdgpu/radv_amdgpu_bo.c"; then
	grep -q DRM_HAIKU_IOCTL_SCANOUT "$W/libdrm/include/drm/drm_haiku.h" \
		&& grep -q __HAIKU__ "$W/libdrm/amdgpu/amdgpu_bo.c" \
		|| die "RADV ($MESA_COMMIT) imports the screen's frame buffer as a KMS handle, but libdrm ($DRM_COMMIT) cannot: pin libdrm at eec11b92 or later (forks/forks.lock.json)"
fi

AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" fetch --no-deps x86_64 \
	"${HAIKUPORTS[@]}" | xargs -n1 basename > "$W/haikuports.txt"
key=$(cat "$0" "$W/haikuports.txt" <(printf '%s\n' "$DRM_COMMIT" "$VA_COMMIT" "$GLVND_COMMIT" \
	"$MESA_COMMIT" "$FFMPEG_COMMIT" "$WLS_COMMIT" "$I965_COMMIT") | sha256sum | cut -c1-16)
if [[ ${FORCE:-0} != 1 && ${CLEAN:-0} != 1 && -f $OUT/key && $(cat "$OUT/key") == "$key" \
		&& -f $OUT/root/lib/libEGL_mesa.so.0 && -f $OUT/addon/lib/libavcodec.a ]]; then
	echo "GPU user land unchanged ($key): $OUT"
	exit 0
fi

note "host wayland-scanner"
. "$AIROS_CI/lib/wayland-scanner.sh"
host_wayland_scanner "$W"

note "Rust for Haiku (NAK, NVK's shader compiler)"
"$AIROS_CI/sdk/build-rust.sh" x86_64
. "$AIROS_TOOLCHAIN/rust/env-x86_64.sh"

note "Mesa's CL compilers for this machine (NVK's precompiled kernels)"
# mesa_clc and vtn_bindgen2 of the same Mesa tree, with Ubuntu's LLVM 18,
# libclc and SPIRV-LLVM-Translator (as deps/build-nvk.sh makes them)
HOST=$AIROS_ROOT/toolchain/mesa-host-amdgpu-${MESA_COMMIT:0:12}
if [[ ! -x $HOST/bin/mesa_clc || ! -x $HOST/bin/vtn_bindgen2 ]]; then
	printf "[binaries]\nllvm-config = '/usr/lib/llvm-18/bin/llvm-config'\n" > "$W/host-native.ini"
	rm -rf "$W/build-host"
	env -u CC -u CXX meson setup "$W/build-host" "$W/mesa" --native-file "$W/host-native.ini" \
		--prefix="$HOST" --libdir=lib --buildtype=debugoptimized --wrap-mode=nofallback \
		'-Dplatforms=[]' '-Dvulkan-drivers=[]' '-Dgallium-drivers=[]' '-Dtools=[]' \
		-Dglx=disabled -Dgbm=disabled -Dgallium-va=disabled -Dglvnd=disabled -Degl=disabled \
		-Dgles1=disabled -Dgles2=disabled -Dopengl=false -Dlibunwind=disabled \
		-Dlmsensors=disabled -Dvalgrind=disabled -Dbuild-tests=false '-Dvideo-codecs=[]' \
		-Dmesa-clc=enabled -Dinstall-mesa-clc=true -Dprecomp-compiler=enabled \
		-Dinstall-precomp-compiler=true -Dllvm=enabled -Dshared-llvm=enabled \
		'-Dstatic-libclc=[]' > "$W/host-configure.log" 2>&1 \
		|| { tail -30 "$W/host-configure.log"; die "host configure failed ($W/host-configure.log)"; }
	ninja -C "$W/build-host" -j"$JOBS" > "$W/host-build.log" 2>&1 \
		|| { grep -m5 -A8 error "$W/host-build.log"; die "host build failed ($W/host-build.log)"; }
	ninja -C "$W/build-host" install > /dev/null
	rm -rf "$W/build-host"
fi
export PATH="$HOST/bin:$PATH"

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
rust = ['rustc', '--target=$RUST_TARGET', '--sysroot=$RUST_SYSROOT', '-C', 'link-arg=--sysroot=$GLROOT', '-C', 'link-arg=-specs=$UNWIND_SPECS']
rust_ld = '${CROSS}gcc'

[host_machine]
system = 'haiku'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
needs_exe_wrapper = true
sys_root = '$GLROOT'
pkg_config_libdir = [${pclist%, }]
bindgen_clang_arguments = ['--target=x86_64-unknown-haiku', '--sysroot=$GLROOT']

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
		--includedir=develop/headers --buildtype=release \
		-Dc_args="$cflags" -Dcpp_args="$cflags" -Dc_link_args="$ldflags" \
		-Dcpp_link_args="$ldflags" "$@" \
		> "$W/$name-configure.log" 2>&1 \
		|| { tail -40 "$W/$name-configure.log"; die "$name configure failed ($W/$name-configure.log)"; }
	mcross ninja -C "$W/build-$name" -j"$JOBS" > "$W/$name-build.log" 2>&1 \
		|| { grep -m5 -B2 -A12 -E 'error|Error' "$W/$name-build.log"; die "$name build failed ($W/$name-build.log)"; }
	DESTDIR=$INSTALL mcross meson install -C "$W/build-$name" --no-rebuild > /dev/null
	DESTDIR=$GLROOT mcross meson install -C "$W/build-$name" --no-rebuild > /dev/null
}

meson_build libdrm "$W/libdrm" "" "$RPATH" --wrap-mode=nofallback \
	-Damdgpu=enabled -Dradeon=disabled -Dintel=enabled -Dnouveau=enabled \
	-Dvmwgfx=disabled -Domap=disabled -Dexynos=disabled -Dfreedreno=disabled \
	-Dtegra=disabled -Dvc4=disabled -Detnaviv=disabled -Dcairo-tests=disabled \
	-Dman-pages=disabled -Dvalgrind=disabled -Dinstall-test-programs=false -Dtests=false

meson_build libva "$W/libva" "$POSITIVE" "$MAPPER" --wrap-mode=nofallback \
	-Ddisable_drm=false -Dwith_x11=no -Dwith_glx=no -Dwith_wayland=no -Dwith_win32=no

# i965 (intel-vaapi-driver), against libdrm_intel, into lib/dri where libva
# looks for drivers
meson_build intel-vaapi-driver "$W/intel-vaapi-driver" "$POSITIVE" "$MAPPER" --wrap-mode=nofallback \
	-Dwith_x11=no -Dwith_wayland=no -Denable_hybrid_codec=false -Denable_tests=false \
	-Ddriverdir=$PREFIX/lib/dri

meson_build libglvnd "$W/libglvnd" "" "" --wrap-mode=nofallback -Dx11=disabled -Dglx=disabled -Dhgl=true \
	-Dgles1=false -Dgles2=true -Degl=true

# (NAK's Rust crates come as Meson subprojects, fetched from crates.io: no
# --wrap-mode=nofallback here)
meson_build mesa "$W/mesa" "$POSITIVE" "$MAPPER" \
	-Dplatforms=haiku,wayland -Degl=enabled -Dglvnd=enabled -Dglx=disabled \
	-Dgbm=disabled -Dopengl=true -Dgles1=disabled -Dgles2=enabled \
	-Dgallium-drivers=radeonsi,nouveau,iris,llvmpipe,softpipe -Dvulkan-drivers=amd,nouveau,intel \
	-Dintel-elk=false \
	-Damd-use-llvm=false -Dllvm=enabled -Dshared-llvm=enabled \
	-Dmesa-clc=system -Dprecomp-compiler=system -Ddisplay-info=disabled \
	-Dgallium-va=enabled -Dvideo-codecs=all -Dgallium-rusticl=false \
	-Dshader-cache=enabled -Dxmlconfig=disabled -Dexpat=disabled \
	-Dzstd=disabled -Dzlib=enabled -Dvalgrind=disabled \
	-Dlibunwind=disabled -Dlmsensors=disabled -Dspirv-tools=disabled \
	-Dbuild-tests=false '-Dtools=[]'

# the in-process Wayland server (lib/wayland-server-inproc.so), which
# libwayland-client loads by name through the library path
meson_build wayland-server "$W/wayland-server" "" "$RPATH" --wrap-mode=nofallback

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
	--enable-decoder=h264,hevc,vp9,av1 --enable-parser=h264,hevc,vp9,av1 \
	--enable-hwaccel=h264_vaapi,hevc_vaapi,vp9_vaapi,av1_vaapi --enable-vaapi \
	> "$W/ffmpeg-configure.log" 2>&1) \
	|| { tail -30 "$W/ffmpeg-configure.log"; die "FFmpeg configure failed ($W/ffmpeg-configure.log)"; }
for hwaccel in H264 HEVC VP9 AV1; do
	grep -q "^CONFIG_${hwaccel}_VAAPI_HWACCEL=yes" "$W/build-ffmpeg/ffbuild/config.mak" \
		|| die "FFmpeg was configured without $hwaccel on VA-API"
done
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
cp "$INSTALL$PREFIX/data/vulkan/icd.d/intel_icd.x86_64.json" "$root/add-ons/vulkan/icd.d/"
grep -q "\"$PREFIX/lib/libvulkan_intel.so\"" "$root/add-ons/vulkan/icd.d/intel_icd.x86_64.json" \
	|| die "ANV's manifest does not name $PREFIX/lib/libvulkan_intel.so"
# NVK on nouveau_drm under a name of its own: the image's NVK on nvidia_rm
# (deps/build-nvk.sh) is lib/libvulkan_nouveau.so with the manifest
# nouveau_icd.x86_64.json in the same directories. A machine has both
# manifests and the loader loads both drivers, each finding only its own
# GPUs; with the same soname the runtime loader would take the second for
# the first, already loaded.
nvkManifest=$INSTALL$PREFIX/data/vulkan/icd.d/nouveau_icd.x86_64.json
grep -q "\"$PREFIX/lib/libvulkan_nouveau.so\"" "$nvkManifest" \
	|| die "NVK's manifest does not name $PREFIX/lib/libvulkan_nouveau.so"
mv "$root/lib/libvulkan_nouveau.so" "$root/lib/libvulkan_nouveau_drm.so"
patchelf --set-soname libvulkan_nouveau_drm.so "$root/lib/libvulkan_nouveau_drm.so"
sed "s|$PREFIX/lib/libvulkan_nouveau.so|$PREFIX/lib/libvulkan_nouveau_drm.so|" "$nvkManifest" \
	> "$root/add-ons/vulkan/icd.d/nouveau_drm_icd.x86_64.json"
find "$root/lib" -type f -name '*.so*' -exec "${CROSS}strip" --strip-unneeded {} +
# Haiku's loader cannot do TLS descriptors or the initial-exec model in
# libraries it loads late.
if find "$root/lib" -type f -name '*.so*' -exec "${CROSS}readelf" -rW {} + 2>/dev/null \
		| grep -qE 'TLSDESC|R_X86_64_TPOFF'; then
	die "unsupported TLS relocations in the GPU libraries"
fi
for lib in libGL.so.1 libEGL.so.1 libGLESv2.so.2 libEGL_mesa.so.0 libvulkan_radeon.so \
		libvulkan_nouveau_drm.so libvulkan_intel.so libdrm.so.2 libdrm_amdgpu.so.1 \
		libdrm_nouveau.so.2 libdrm_intel.so.1 libva.so.2 libva-drm.so.2 \
		dri/radeonsi_drv_video.so dri/nouveau_drv_video.so dri/i965_drv_video.so \
		wayland-server-inproc.so; do
	[[ -e $root/lib/$lib ]] || die "no $lib"
done
printf 'libdrm %s\nlibva %s\nlibglvnd %s\nmesa %s\nintel-vaapi-driver %s\nffmpeg %s\nwayland-server %s\nllvm %s\nrust %s\n' \
	"$DRM_COMMIT" "$VA_COMMIT" "$GLVND_COMMIT" "$MESA_COMMIT" "$I965_COMMIT" "$FFMPEG_COMMIT" "$WLS_COMMIT" \
	"$llvm_version" "$(rustc --version)" > "$W/sources.txt"
rsync -rlc --chmod=g+rwX --delete "$root/" "$OUT/root/"
rsync -rlc --chmod=g+rwX --delete "$ADDON/" "$OUT/addon/"
cp "$W/sources.txt" "$W/haikuports.json" "$OUT/"
echo "$key" > "$OUT/key"
du -sh "$OUT/root"
find "$OUT/root" \( -type f -o -type l \) | sed "s|$OUT/root/||" | sort
