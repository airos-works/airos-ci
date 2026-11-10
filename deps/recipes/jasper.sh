# JasPer 2.0.33 for the arm64 system, the version x86_64 images have from
# HaikuPorts, built as HaikuPorts builds it (media-libs/jasper): CMake,
# shared, with JPEG (libjpeg_turbo.sh, named to CMake, whose search in the
# cross tree does not find it); without the OpenGL viewer jiv or the
# other programs (HaikuPorts' jasper_tools). Packaged as HaikuPorts' jasper
# and jasper_devel (build-deps.sh library_packages): Haiku's arm64 build
# makes the JPEG 2000 translator with them, and the ICNS translator links
# them too.
VERSION=2.0.33
NO_PACKAGE=1
SOURCE_URL=https://github.com/mdadams/jasper/archive/version-$VERSION.tar.gz
SOURCE_SHA256=38b8f74565ee9e7fec44657e69adb5c9b2a966ca5947ced5717cde18a7d2eca6
SUMMARY="JasPer JPEG 2000 codec"
COPYRIGHTS="1999-2021 Michael D. Adams"
LICENSES="JasPer v2"
LICENSE_FILES="JasPer v2=LICENSE"
HOMEPAGE=https://www.ece.uvic.ca/~frodo/jasper/
PACKAGE_REQUIRES="lib:libjpeg >= 62"
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
}
build() {
	[[ $ARCH == arm64 ]] || die "jasper is built for arm64 only (x86_64 has HaikuPorts')"
	# The build directory may not be the source's "build" (JasPer refuses it).
	cmake_build -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DJAS_ENABLE_AUTOMATIC_DEPENDENCIES=OFF \
		-DCMAKE_SKIP_RPATH=ON -DJAS_ENABLE_OPENGL=OFF -DJAS_ENABLE_LIBJPEG=ON \
		-DJAS_ENABLE_PROGRAMS=OFF -DJAS_ENABLE_DOC=OFF -DJAS_ENABLE_SHARED=ON \
		-DJPEG_INCLUDE_DIR="$DEPS/develop/headers" -DJPEG_LIBRARY="$DEPS/develop/lib/libjpeg.so"
	normalize_stage
	${CROSS}readelf -d "$STAGE$PREFIX"/lib/libjasper.so.*.*.* > _build/needed.txt
	grep -q 'NEEDED.*\[libjpeg\.so' _build/needed.txt || die "JasPer without JPEG"
	library_packages jasper
}
