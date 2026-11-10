# libtiff 4.7.2 for the arm64 system, built as HaikuPorts builds it
# (media-libs/tiff/tiff-4.7.2.recipe; x86_64 images have its 4.7.0): autotools,
# shared, libtiff, with JPEG (libjpeg_turbo.sh) and zlib
# compression as HaikuPorts' requires them; no LZMA, Zstandard, WebP, JBIG,
# LERC or libdeflate codecs. Without libtiffxx, the C++ stream interface:
# libtool links C++ libraries against the cross compiler's libstdc++.a, which
# the toolchain does not have, and nothing on the system uses it. Packaged as HaikuPorts' tiff and tiff_devel
# (build-deps.sh library_packages): Haiku's arm64 build makes the TIFF
# translator with them.
VERSION=4.7.2
NO_PACKAGE=1
SOURCE_URL=https://download.osgeo.org/libtiff/tiff-$VERSION.tar.gz
SOURCE_SHA256=672bd7d10aee4606171afb864f3570b83340f6a33e2c186dc0512f7145ffdf6a
SUMMARY="libtiff TIFF image library"
COPYRIGHTS="1988-1997 Sam Leffler
1991-1997 Silicon Graphics, Inc."
LICENSES="MIT"
HOMEPAGE=http://www.libtiff.org/
PACKAGE_REQUIRES="lib:libjpeg >= 62
lib:libz >= 1"
# download.osgeo.org drops TLS connections from the build server (November
# 2026); Fossies has the same release tarball.
SOURCE_MIRROR=https://fossies.org/linux/misc/tiff-$VERSION.tar.gz
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256" "$SOURCE_MIRROR"
}
build() {
	[[ $ARCH == arm64 ]] || die "tiff is built for arm64 only (x86_64 has HaikuPorts')"
	configure_ac --disable-static --disable-docs --disable-tests --disable-contrib \
		--enable-jpeg --enable-zlib --disable-lzma --disable-zstd --disable-webp \
		--disable-jbig --disable-lerc --disable-libdeflate --disable-old-jpeg --disable-cxx
	grep -q '^#define JPEG_SUPPORT 1' libtiff/tiffconf.h || die "libtiff without JPEG"
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
	normalize_stage
	library_packages tiff
}
