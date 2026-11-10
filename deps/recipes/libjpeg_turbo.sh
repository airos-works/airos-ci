# libjpeg-turbo 3.1.4.1 for the arm64 system, the version x86_64 images have
# from HaikuPorts, built as HaikuPorts builds it
# (media-libs/libjpeg-turbo/libjpeg_turbo-3.1.4.1.recipe): CMake, shared
# only, the libjpeg 6.2 ABI (libjpeg.so.62) with the NEON SIMD code, and
# libturbojpeg. Packaged as HaikuPorts' libjpeg_turbo and libjpeg_turbo_devel
# (build-deps.sh library_packages). Haiku's arm64 build makes the JPEG
# translator with them, and the USB webcam add-on its MJPEG decoding;
# libtiff, Jasper and libwebp build on it (tiff.sh, jasper.sh).
VERSION=3.1.4.1
NO_PACKAGE=1
SOURCE_URL=https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/$VERSION.tar.gz
SOURCE_SHA256=a7da42b640377c2a9a9665e2c4b0ea60cd5599afb48c2521e6df0c9dc9d15a25
SUMMARY="libjpeg-turbo JPEG image codec"
COPYRIGHTS="1991-2019 Thomas G. Lane, Guido Vollbeding
2000-2023 D. R. Commander
2013 Linaro Limited
2015 Google, Inc.
2015-2022 Matthieu Darbois"
LICENSES="BSD (3-clause)
IJG
Zlib"
LICENSE_FILES="IJG=README.ijg"
HOMEPAGE=https://www.libjpeg-turbo.org/
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
}
build() {
	[[ $ARCH == arm64 ]] || die "libjpeg_turbo is built for arm64 only (x86_64 has HaikuPorts')"
	# REQUIRE_SIMD: fail, rather than warn and leave the NEON code out
	cmake_build -DENABLE_STATIC=OFF -DCMAKE_SKIP_RPATH=ON -DWITH_SIMD=ON -DREQUIRE_SIMD=ON
	normalize_stage
	library_packages libjpeg_turbo
}
