#!/usr/bin/env bash
# build-nvk.sh
#
# NVK, Mesa's Vulkan driver for NVIDIA, on nvidia_rm (X547's nvrm back end and
# the X399's patches: airos-works/mesa-nvk airos-nvk-r2), cross-built for x86_64
# as docs/x399-workstation/tools/haiku-build-nvk.sh builds it natively:
#
#   1. Mesa's host compilers (mesa_clc, vtn_bindgen2) from the same tree, with
#      Ubuntu's LLVM 18, libclc and SPIRV-LLVM-Translator;
#   2. Rust for Haiku (sdk/build-rust.sh), for NAK, NVK's shader compiler;
#   3. the driver, against the x86_64 SDK, HaikuPorts' Wayland (the swapchain
#      presents through Haiku's in-process Wayland server, as RADV's does) and
#      airos-works/open-gpu-kernel-modules (nvrm's RM headers).
#
# Results in $AIROS_ROOT/image-inputs/x86_64/nvk: lib/libvulkan_nouveau.so for
# system/non-packaged/lib and add-ons/vulkan/icd.d/nouveau_icd.x86_64.json,
# where HaikuPorts' Vulkan loader finds it.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
if [[ ${AIROS_LOCKED:-} != haiku-x86_64 ]]; then
	exec env AIROS_LOCKED=haiku-x86_64 flock "$AIROS_LOCKS/haiku-x86_64.lock" "$0" "$@"
fi
export AIROS_ARCH=x86_64
. "$AIROS_CI/lib/sdk.sh"
. "$AIROS_CI/lib/fork.sh"

W=$AIROS_WORK/nvk
INPUTS=$AIROS_ROOT/image-inputs/x86_64/nvk
mkdir -p "$W"
cd "$W"
# Haiku's runtime_loader implements only general-dynamic TLS (no TLSDESC).
TLS=-mtls-dialect=gnu

note "Rust for Haiku"
"$AIROS_CI/sdk/build-rust.sh" x86_64
. "$AIROS_TOOLCHAIN/rust/env-x86_64.sh"

note "sources"
fork_checkout mesa-nvk "$W/mesa-nvk"; NVK_COMMIT=$FORK_COMMIT
fork_checkout open-gpu-kernel-modules "$W/open-gpu-kernel-modules"; OGKM_COMMIT=$FORK_COMMIT
MESA=$W/mesa-nvk
# nvrm expects NVIDIA's open-gpu-kernel-modules inside it
ln -sfn "$W/open-gpu-kernel-modules" "$MESA/src/nouveau/vulkan/nvkmd/nvrm/open-gpu-kernel-modules"

note "host compilers"
HOST=$AIROS_ROOT/toolchain/mesa-host-nvk-${NVK_COMMIT:0:12}
if [[ ! -x $HOST/bin/mesa_clc ]]; then
	printf "[binaries]\nllvm-config = '/usr/lib/llvm-18/bin/llvm-config'\n" > "$W/native.ini"
	rm -rf "$W/host-build"
	env -u CC -u CXX meson setup "$W/host-build" "$MESA" --native-file "$W/native.ini" \
		--prefix="$HOST" --libdir=lib --buildtype=debugoptimized --wrap-mode=nofallback \
		'-Dplatforms=[]' '-Dvulkan-drivers=[]' '-Dgallium-drivers=[]' '-Dtools=[]' \
		-Dglx=disabled -Dgbm=disabled -Dgallium-va=disabled -Dglvnd=disabled -Degl=disabled \
		-Dgles1=disabled -Dgles2=disabled -Dopengl=false -Dlibunwind=disabled \
		-Dlmsensors=disabled -Dvalgrind=disabled -Dbuild-tests=false '-Dvideo-codecs=[]' \
		-Dmesa-clc=enabled -Dinstall-mesa-clc=true -Dprecomp-compiler=enabled \
		-Dinstall-precomp-compiler=true -Dllvm=enabled -Dshared-llvm=enabled \
		'-Dstatic-libclc=[]' > "$W/host-configure.log" 2>&1 \
		|| { tail -30 "$W/host-configure.log"; die "host configure failed"; }
	ninja -C "$W/host-build" -j"$JOBS" > "$W/host-build.log" 2>&1 \
		|| { grep -m5 -A8 error "$W/host-build.log"; die "host build failed"; }
	ninja -C "$W/host-build" install > /dev/null
fi
export PATH="$HOST/bin:$PATH"

note "host wayland-scanner"
. "$AIROS_CI/lib/wayland-scanner.sh"
host_wayland_scanner "$W"

note "sysroot: the SDK's and HaikuPorts' Wayland"
# Vulkan windows (VK_KHR_wayland_surface, VK_KHR_swapchain): without a
# platform NVK offers no surface at all and no swapchain program can start.
NVKROOT=$W/sysroot
system=$NVKROOT/boot/system
rsync -a --delete --exclude=/boot/system/data/ssl/private "$SYSROOT/" "$NVKROOT/"
AIROS_CACHE=$AIROS_CACHE AIROS_SDK=$AIROS_SDK "$AIROS_CI/deps/haikuports.py" stage --no-deps x86_64 \
	"$system" wayland wayland_devel wayland_protocols libffi libffi_devel > /dev/null
# pkg-config files of packages name their package's mount point
# (/packages/<name>/.self) as the prefix; in the sysroot it is /boot/system
find "$system" -path '*/pkgconfig/*.pc' -type f \
	-exec sed -i 's|^prefix=/packages/[^/]*/\.self|prefix=/boot/system|' {} +
while IFS= read -r -d '' link; do
	target=$(readlink "$link")
	[[ $target == /boot/system/* ]] && ln -sfn "$(realpath -m --relative-to="$(dirname "$link")" "$NVKROOT$target")" "$link"
done < <(find "$system" -type l -print0)

note "NVK"
cat > "$W/cross.ini" <<EOF
[binaries]
c = '${CROSS}gcc'
cpp = '${CROSS}g++'
ar = '${CROSS}ar'
strip = '${CROSS}strip'
pkg-config = '/usr/bin/pkg-config'
rust = ['rustc', '--target=$RUST_TARGET', '--sysroot=$RUST_SYSROOT', '-C', 'link-arg=--sysroot=$NVKROOT', '-C', 'link-arg=-specs=$UNWIND_SPECS']
rust_ld = '${CROSS}gcc'

[host_machine]
system = 'haiku'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'

[properties]
needs_exe_wrapper = true
sys_root = '$NVKROOT'
pkg_config_libdir = ['$system/develop/lib/pkgconfig', '$system/lib/pkgconfig', '$system/data/pkgconfig']
bindgen_clang_arguments = ['--target=x86_64-unknown-haiku', '--sysroot=$NVKROOT']

[built-in options]
c_args = ['--sysroot=$NVKROOT', '$TLS']
cpp_args = ['--sysroot=$NVKROOT', '$TLS']
c_link_args = ['--sysroot=$NVKROOT', '-specs=$UNWIND_SPECS']
cpp_link_args = ['--sysroot=$NVKROOT', '-specs=$UNWIND_SPECS']
EOF
cat > "$W/native.ini" <<EOF
[built-in options]
pkg_config_path = ['$HOSTPC']
EOF
B=$W/build
key=$(cat "$W/cross.ini" "$W/native.ini" "$system/.haikuports.json" \
	<(echo "$NVK_COMMIT $OGKM_COMMIT") | sha256sum | cut -c1-16)
if [[ ! -f $B/build.ninja || $(cat "$B.key" 2>/dev/null) != "$key" ]]; then
	rm -rf "$B"
	env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u LDFLAGS \
		-u PKG_CONFIG_LIBDIR -u PKG_CONFIG_SYSROOT_DIR -u PKG_CONFIG_PATH \
		meson setup "$B" "$MESA" --cross-file "$W/cross.ini" --native-file "$W/native.ini" \
		--prefix=/boot/system --libdir=lib --buildtype=release \
		'-Dgallium-drivers=[]' -Dvulkan-drivers=nouveau -Dplatforms=wayland \
		-Dgallium-rusticl=false -Degl=disabled -Dglvnd=disabled -Dglx=disabled -Dgbm=disabled \
		-Dopengl=false -Dgles1=disabled -Dgles2=disabled -Ddisplay-info=disabled \
		-Dllvm=disabled -Dmesa-clc=system -Dprecomp-compiler=system -Dzstd=disabled \
		-Dvalgrind=disabled -Dlibunwind=disabled -Dlmsensors=disabled -Dbuild-tests=false \
		'-Dtools=[]' > "$B.configure.log" 2>&1 \
		|| { tail -40 "$B.configure.log"; die "NVK configure failed (log: $B.configure.log)"; }
	echo "$key" > "$B.key"
fi
ninja -C "$B" -j"$JOBS" > "$B.build.log" 2>&1 \
	|| { grep -m5 -B3 -A10 -E 'error(\[|:)' "$B.build.log"; die "NVK build failed (log: $B.build.log)"; }
rm -rf "$W/install"
DESTDIR=$W/install meson install -C "$B" --no-rebuild > /dev/null
driver=$(find "$W/install" -name 'libvulkan_nouveau.so' | head -n 1)
[[ -n $driver ]] || die "no libvulkan_nouveau.so installed"
if ${CROSS}readelf -rW "$driver" | grep -qE 'TLSDESC|R_X86_64_TPOFF'; then
	die "libvulkan_nouveau.so has TLS relocations Haiku's loader cannot do"
fi

note "image inputs"
stage=$W/stage
rm -rf "$stage"
mkdir -p "$stage/lib" "$stage/add-ons/vulkan/icd.d"
cp "$driver" "$stage/lib/"
${CROSS}strip --strip-unneeded "$stage/lib/libvulkan_nouveau.so"
icd=$(find "$W/install" -name 'nouveau_icd*.json' | head -n 1)
[[ -n $icd ]] || die "no nouveau ICD manifest installed"
python3 - "$icd" "$stage/add-ons/vulkan/icd.d/$(basename "$icd")" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d["ICD"]["library_path"] = "/boot/system/non-packaged/lib/libvulkan_nouveau.so"
json.dump(d, open(sys.argv[2], "w"), indent=4)
PY
printf 'mesa-nvk %s\nopen-gpu-kernel-modules %s\nhaiku %s\nrust %s\n' "$NVK_COMMIT" "$OGKM_COMMIT" \
	"$HAIKU_REVISION" "$(rustc --version)" > "$stage/nvk-sources.txt"
mkdir -p "$INPUTS"
rsync -rlc --delete "$stage/" "$INPUTS/"
${CROSS}readelf -d "$INPUTS/lib/libvulkan_nouveau.so" | grep NEEDED
cat "$INPUTS/add-ons/vulkan/icd.d/"*.json
