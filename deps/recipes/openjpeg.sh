# OpenJPEG 2.5.4 for the arm64 system, built as HaikuPorts builds it
# (media-libs/openjpeg/openjpeg-2.5.4.recipe; x86_64 images have its 2.5.3):
# CMake, shared; the library only, without opj_compress and its siblings,
# which would pull in LCMS, PNG and TIFF. libicns reads and writes the JPEG
# 2000 icons of ICNS files with it (libicns.sh), as HaikuPorts' does.
# Packaged as HaikuPorts' openjpeg and openjpeg_devel (build-deps.sh
# library_packages).
VERSION=2.5.4
NO_PACKAGE=1
SOURCE_URL=https://github.com/uclouvain/openjpeg/archive/v$VERSION.tar.gz
SOURCE_SHA256=a695fbe19c0165f295a8531b1e4e855cd94d0875d2f88ec4b61080677e27188a
SUMMARY="OpenJPEG JPEG 2000 codec"
COPYRIGHTS="2002-2014 Universite catholique de Louvain (UCL), Belgium
2002-2014 Professor Benoit Macq
2003-2014 Antonin Descampe
2011-2012 Centre National d'Etudes Spatiales (CNES), France
2012 CS Systemes d'Information, France"
LICENSES="BSD (2-clause)"
HOMEPAGE=https://www.openjpeg.org/
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
}
build() {
	[[ $ARCH == arm64 ]] || die "openjpeg is built for arm64 only (x86_64 has HaikuPorts')"
	cmake_build -DBUILD_SHARED_LIBS=ON -DBUILD_STATIC_LIBS=OFF -DBUILD_TESTING=OFF \
		-DBUILD_CODEC=OFF -DCMAKE_SKIP_RPATH=ON
	normalize_stage
	library_packages openjpeg
}
