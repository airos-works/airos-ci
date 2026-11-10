# libwebp 1.6.0 for the arm64 system, the version x86_64 images have from
# HaikuPorts, built as HaikuPorts builds it (media-libs/libwebp): CMake,
# shared, NDEBUG. The libraries only (libwebp, libwebpdecoder, libwebpdemux,
# libwebpmux and libsharpyuv), without the command-line tools, which are
# HaikuPorts' libwebp_tools and would pull in GIF, PNG and TIFF readers.
# Packaged as HaikuPorts' libwebp and libwebp_devel (build-deps.sh
# library_packages): Haiku's arm64 build makes the WebP translator with them,
# and libavif uses libsharpyuv (libavif.sh).
VERSION=1.6.0
NO_PACKAGE=1
SOURCE_URL=https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-$VERSION.tar.gz
SOURCE_SHA256=e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564
SUMMARY="libwebp WebP image codec"
COPYRIGHTS="2010-2025 Google Inc."
LICENSES="BSD (3-clause)"
HOMEPAGE=https://developers.google.com/speed/webp
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
}
build() {
	[[ $ARCH == arm64 ]] || die "libwebp is built for arm64 only (x86_64 has HaikuPorts')"
	CFLAGS="$CFLAGS -DNDEBUG" cmake_build -DBUILD_SHARED_LIBS=ON -DCMAKE_SKIP_RPATH=ON \
		-DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF \
		-DWEBP_BUILD_GIF2WEBP=OFF -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF \
		-DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF -DWEBP_BUILD_EXTRAS=OFF
	normalize_stage
	# sharpyuv's headers are in webp/sharpyuv, and its users include
	# <sharpyuv/sharpyuv.h> (HaikuPorts' recipe fixes it the same way)
	sed -i 's|^includedir=.*|includedir=${prefix}/develop/headers/webp|' \
		"$STAGE$PREFIX/develop/lib/pkgconfig/libsharpyuv.pc"
	library_packages libwebp
}
