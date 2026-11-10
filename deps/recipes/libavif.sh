# libavif 1.4.2 for the arm64 system, the version x86_64 images have from
# HaikuPorts (media-libs/libavif/libavif1.0-1.4.2.recipe): CMake, shared,
# decoding with dav1d (dav1d.sh) and libsharpyuv from libwebp (libwebp.sh).
# HaikuPorts encodes with rav1e, which is Rust and has no arm64 Haiku build;
# this build encodes with libaom (libaom.sh). Not SVT-AV1 (svt_av1.sh): it
# encodes only 4:2:0, and the AVIF translator writes 4:4:4 by default. The
# codecs' headers and libraries are named to CMake: its search in the cross
# tree finds none of them. No libyuv, libxml2 or apps (HaikuPorts'
# libavif1.0_tools). Packaged as HaikuPorts' libavif1.0 and libavif1.0_devel (build-deps.sh
# library_packages): Haiku's arm64 build makes the AVIF translator with them.
VERSION=1.4.2
NO_PACKAGE=1
SOURCE_URL=https://github.com/AOMediaCodec/libavif/archive/v$VERSION.tar.gz
SOURCE_SHA256=2b645287340ba5a631d268b551dc2d72bd73ac33335962dd36dcdb6d8366921d
SUMMARY="libavif AVIF image codec"
COPYRIGHTS="2019 Joe Drago"
LICENSES="BSD (2-clause)"
HOMEPAGE=https://github.com/AOMediaCodec/libavif
PACKAGE_REQUIRES="lib:libdav1d >= 7
lib:libaom >= 3
lib:libsharpyuv >= 0"
# rebuilt when the codecs change
STAMP_EXTRA="dav1d:$(sha256sum "$AIROS_CI/deps/recipes/dav1d.sh" | cut -c1-16) aom:$(sha256sum "$AIROS_CI/deps/recipes/libaom.sh" | cut -c1-16) webp:$(sha256sum "$AIROS_CI/deps/recipes/libwebp.sh" | cut -c1-16)"
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
}
build() {
	[[ $ARCH == arm64 ]] || die "libavif is built for arm64 only (x86_64 has HaikuPorts')"
	cmake_build -DBUILD_SHARED_LIBS=ON -DCMAKE_SKIP_RPATH=ON -DAVIF_BUILD_APPS=OFF \
		-DAVIF_BUILD_TESTS=OFF -DAVIF_CODEC_DAV1D=SYSTEM -DAVIF_CODEC_SVT=OFF \
		-DAVIF_CODEC_AOM=SYSTEM -DAVIF_CODEC_AOM_DECODE=OFF -DAVIF_CODEC_AOM_ENCODE=ON \
		-DAVIF_CODEC_RAV1E=OFF -DAVIF_LIBSHARPYUV=SYSTEM \
		-DAVIF_LIBYUV=OFF -DAVIF_LIBXML2=OFF -DAVIF_JPEG=OFF -DAVIF_ZLIBPNG=OFF \
		-DLIBSHARPYUV_INCLUDE_DIR="$DEPS/develop/headers/webp" \
		-DLIBSHARPYUV_LIBRARY="$DEPS/develop/lib/libsharpyuv.so" \
		-DDAV1D_INCLUDE_DIR="$DEPS/develop/headers" -DDAV1D_LIBRARY="$DEPS/develop/lib/libdav1d.so" \
		-DAOM_INCLUDE_DIR="$DEPS/develop/headers" -DAOM_LIBRARY="$DEPS/develop/lib/libaom.so" \
		-Wno-dev
	normalize_stage
	local lib
	lib=$(ls "$STAGE$PREFIX"/lib/libavif.so.*.*.*)
	${CROSS}readelf -d "$lib" > _build/needed.txt
	for needed in libdav1d libaom libsharpyuv; do
		grep -q "NEEDED.*\[$needed\.so" _build/needed.txt || die "libavif does not use $needed"
	done
	library_packages libavif1.0
}
