# dav1d 1.5.4 for the arm64 system, the version x86_64 images have from
# HaikuPorts, built as HaikuPorts builds it (media-libs/dav1d): meson,
# debugoptimized, with the AArch64 assembly; the library only, without the
# dav1d command or the tests. libavif decodes AV1 pictures with it
# (libavif.sh). Packaged as HaikuPorts' dav1d and dav1d_devel (build-deps.sh
# library_packages).
VERSION=1.5.4
NO_PACKAGE=1
SOURCE_URL=https://code.videolan.org/videolan/dav1d/-/archive/$VERSION/dav1d-$VERSION.tar.bz2
SOURCE_SHA256=2abfb0c89212e6e4733a54e0ae509ec00a5b845a6360946f918806e14aedb011
SUMMARY="dav1d AV1 decoder"
COPYRIGHTS="2018-2026 VideoLAN and dav1d authors"
LICENSES="BSD (2-clause)"
HOMEPAGE=https://code.videolan.org/videolan/dav1d
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
}
build() {
	[[ $ARCH == arm64 ]] || die "dav1d is built for arm64 only (x86_64 has HaikuPorts')"
	cat > _cross.ini <<CROSS
[binaries]
c = '${CROSS}gcc'
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

[built-in options]
c_args = ['--sysroot=$SYSROOT']
c_link_args = ['--sysroot=$SYSROOT', '-specs=$UNWIND_SPECS']
CROSS
	rm -rf _b
	env -u CC -u CXX -u CFLAGS -u CXXFLAGS -u CPPFLAGS -u LDFLAGS \
		meson setup _b . --cross-file=_cross.ini --wrap-mode=nofallback \
		--prefix=$PREFIX --libdir=lib --includedir=develop/headers \
		--buildtype=debugoptimized -Denable_tools=false -Denable_tests=false \
		-Denable_examples=false -Denable_asm=true
	ninja -C _b -j"$JOBS"
	DESTDIR=$STAGE ninja -C _b install
	normalize_stage
	library_packages dav1d
}
