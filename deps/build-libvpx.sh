#!/usr/bin/env bash
# build-libvpx.sh
#
# libvpx 1.16.0 for the x86_64 images, built for x86-64 with VP9's high bit
# depth: FFmpeg's libvpx-vp9 encoder (which MediaConverter uses) then takes
# 10-bit pictures, for HandBrake's "VP9 10-bit". HaikuPorts' libvpx1.16 has
# neither: libvpx's configure does not know Haiku and builds its generic C
# target, and high bit depth is off by default. This build, from the same
# release tarball (HaikuPorts' checksum), is the Linux x86-64 target with the
# Haiku cross compiler: same soname (libvpx.so.12), same API, SSE to AVX2,
# twice as fast at VP9 on the X399 and bit for bit the same output.
#
# It goes to $AIROS_ROOT/image-inputs/x86_64/libvpx/lib, which the x86_64 image
# puts in system/non-packaged/lib, ahead of HaikuPorts' copy in the library
# path. images/build-image.sh x86_64 runs it with every image build; it does
# nothing while the version and this script stay the same.
set -euo pipefail
umask 002
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
if [[ ${AIROS_LOCKED:-} != haiku-x86_64 ]]; then
	exec env AIROS_LOCKED=haiku-x86_64 flock "$AIROS_LOCKS/haiku-x86_64.lock" "$0" "$@"
fi
export AIROS_ARCH=x86_64
. "$AIROS_CI/lib/sdk.sh"

VERSION=1.16.0
SHA256=7a479a3c66b9f5d5542a4c6a1b7d3768a983b1e5c14c60a9396edc9b649e015c
URL=https://github.com/webmproject/libvpx/archive/v$VERSION.tar.gz

W=$AIROS_WORK/libvpx
OUT=$AIROS_ROOT/image-inputs/x86_64/libvpx
STAMP="$VERSION $(sha256sum "$0" | cut -c1-16)"
if [[ ${FORCE:-0} != 1 && -f $OUT/stamp && $(cat "$OUT/stamp") == "$STAMP" ]]; then
	echo "== libvpx $VERSION (up to date)"
	exit 0
fi
command -v nasm > /dev/null || die "libvpx's x86 code needs nasm on the build server"

note "libvpx $VERSION"
tarball=$AIROS_CACHE/libvpx-$VERSION.tar.gz
mkdir -p "$AIROS_CACHE"
if [[ ! -f $tarball ]] || ! echo "$SHA256  $tarball" | sha256sum -c --quiet; then
	curl -fsSL -o "$tarball.part" "$URL"
	echo "$SHA256  $tarball.part" | sha256sum -c --quiet || die "libvpx $VERSION: checksum mismatch"
	mv "$tarball.part" "$tarball"
fi
rm -rf "$W"
mkdir -p "$W/stub"
tar xzf "$tarball" -C "$W"
# The Linux target links -lpthread and -lm, which are libroot on Haiku.
${CROSS}ar rc "$W/stub/libpthread.a"
${CROSS}ar rc "$W/stub/libm.a"
cd "$W/libvpx-$VERSION"
export CROSS
LDFLAGS="--sysroot=$SYSROOT -L$W/stub -specs=$UNWIND_SPECS" ./configure \
	--target=x86_64-linux-gcc --prefix=/boot/system --libdir=/boot/system/lib --as=nasm \
	--enable-pic --enable-shared --disable-static --enable-vp8 --enable-vp9 \
	--enable-postproc --enable-vp9-highbitdepth --disable-examples --disable-tools \
	--disable-docs --disable-unit-tests \
	--extra-cflags="--sysroot=$SYSROOT" --extra-cxxflags="--sysroot=$SYSROOT" > "$W/configure.log" 2>&1 \
	|| { tail -20 "$W/configure.log"; die "libvpx configure failed"; }
make -j"$JOBS" > "$W/make.log" 2>&1 || { tail -40 "$W/make.log"; die "libvpx build failed"; }
soname=$(${CROSS}readelf -d libvpx.so.12.0.0 | sed -n 's/.*(SONAME).*\[\(.*\)\]/\1/p')
[[ $soname == libvpx.so.12 ]] || die "libvpx's soname is $soname, not HaikuPorts' libvpx.so.12"
grep -q "CONFIG_VP9_HIGHBITDEPTH 1" vpx_config.h || die "libvpx was built without high bit depth"

rm -rf "$OUT"
mkdir -p "$OUT/lib"
cp libvpx.so.12.0.0 "$OUT/lib/libvpx.so.12"
${CROSS}strip --strip-unneeded "$OUT/lib/libvpx.so.12"
cp LICENSE "$OUT/LICENSE"
printf 'libvpx %s from %s (sha256 %s), high bit depth, x86_64-linux-gcc target\n' \
	"$VERSION" "$URL" "$SHA256" > "$OUT/sources.txt"
echo "$STAMP" > "$OUT/stamp"
echo "libvpx: $OUT/lib/libvpx.so.12"
