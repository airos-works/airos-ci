# libvpx (arm64): VP8 and VP9, with VP9's high bit depth, for FFmpeg's
# libvpx encoders (rock5_ffmpeg, MediaConverter's VP8/VP9 and VP9 10-bit).
# The release HaikuPorts packages, built as libvpx's Linux AArch64 target
# (its configure does not know Haiku and would fall back to plain C). It has
# no way to ask Haiku what the processor can do, so it is plain Armv8 NEON,
# which every board has (the Pi 4's Cortex-A72 has no dot product). x86_64
# images have deps/build-libvpx.sh.
VERSION=1.16.0
SOURCE_URL=https://github.com/webmproject/libvpx/archive/v1.16.0.tar.gz
SOURCE_SHA256=7a479a3c66b9f5d5542a4c6a1b7d3768a983b1e5c14c60a9396edc9b649e015c
SUMMARY="WebM VP8/VP9 codec library, with VP9 high bit depth"
COPYRIGHT="2010-2026 The WebM project authors"
LICENSE="BSD (3-clause)"
fetch_source() { fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"; }
build() {
	[[ $ARCH == arm64 ]] || die "this libvpx recipe is for arm64 (x86_64: deps/build-libvpx.sh)"
	CROSS=$CROSS LDFLAGS="--sysroot=$SYSROOT -specs=$UNWIND_SPECS" ./configure \
		--target=arm64-linux-gcc --prefix=$PREFIX --libdir=$PREFIX/lib \
		--enable-pic --enable-shared --disable-static --enable-vp8 --enable-vp9 \
		--enable-postproc --enable-vp9-highbitdepth --disable-examples --disable-tools \
		--disable-docs --disable-unit-tests \
		--disable-runtime-cpu-detect --disable-neon-dotprod --disable-neon-i8mm \
		--disable-sve --disable-sve2 \
		--extra-cflags="--sysroot=$SYSROOT" --extra-cxxflags="--sysroot=$SYSROOT"
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
	grep -q "CONFIG_VP9_HIGHBITDEPTH 1" vpx_config.h
	grep -q "HAVE_NEON 1" vpx_config.h
}
