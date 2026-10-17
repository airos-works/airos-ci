# x264 (arm64): the H.264 encoder MediaConverter opens at run time
# (libx264.so.164), from the same snapshot as HaikuPorts' x264-20220222 for
# x86_64, with x264's AArch64 NEON code.
VERSION=0.164.20220222
SOURCE_URL=https://github.com/mirror/x264/archive/bfc87b7a330f75f5c9a21e56081e4b20344f139e.tar.gz
SOURCE_SHA256=2ca2344fc2d657150599687e128dac8816b07e8d5c991fa2281e51fe647bbbe7
SUMMARY="x264 H.264/AVC encoder library"
COPYRIGHT="2003-2022 x264 project"
LICENSE="GNU GPL v2"
fetch_source() { fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"; }
build() {
	[[ $ARCH == arm64 ]] || die "x264 is built for arm64 only (x86_64 has HaikuPorts')"
	./configure --host="$TRIPLET" --cross-prefix="$CROSS" --sysroot="$SYSROOT" \
		--prefix=$PREFIX --libdir=$PREFIX/lib --includedir=$PREFIX/develop/headers \
		--enable-pic --enable-shared --disable-cli \
		--extra-ldflags="-Wl,-Bsymbolic -specs=$UNWIND_SPECS"
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
}
