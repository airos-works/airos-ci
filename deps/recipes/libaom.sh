# libaom 3.15.3 (the AV1 reference codec) for the arm64 system: libavif's AV1
# encoder (libavif.sh). x86_64's HaikuPorts libavif encodes with rav1e, which
# is Rust and has no arm64 Haiku build; SVT-AV1 (svt_av1.sh) encodes 4:2:0
# only, and the AVIF translator writes 4:4:4 by default and losslessly in
# 4:4:4. libaom encodes every format libavif asks for.
#
# CMake from the release tarball (signed by the AOMedia release key), shared,
# the encoder only (dav1d decodes, dav1d.sh), NEON and CRC32 but no run-time
# CPU detection (libaom reads the CPU's features from Linux and Windows
# interfaces Haiku does not have), so no Dot Product, I8MM or SVE code either:
# the Raspberry Pi 4's Cortex-A72 has none of them. No HaikuPorts package
# exists; packaged as libaom and libaom_devel with HaikuPorts' conventions
# (build-deps.sh library_packages).
VERSION=3.15.3
NO_PACKAGE=1
SOURCE_URL=https://storage.googleapis.com/aom-releases/libaom-$VERSION.tar.gz
SOURCE_SHA256=12c01dc731ed7b5a999e28120b45bf58a002ba3435a4ba2cfbc1e084a27c9c04
SUMMARY="libaom AV1 codec"
COPYRIGHTS="2016-2025 Alliance for Open Media"
LICENSES="BSD (2-clause)
AOMedia Patent License 1.0"
LICENSE_FILES="AOMedia Patent License 1.0=PATENTS"
HOMEPAGE=https://aomedia.googlesource.com/aom
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
}
build() {
	[[ $ARCH == arm64 ]] || die "libaom is built for arm64 only"
	cmake_build -DBUILD_SHARED_LIBS=ON -DCMAKE_SKIP_RPATH=ON -DAOM_TARGET_CPU=arm64 \
		-DCONFIG_RUNTIME_CPU_DETECT=0 -DENABLE_NEON=ON -DENABLE_ARM_CRC32=ON \
		-DENABLE_NEON_DOTPROD=OFF -DENABLE_NEON_I8MM=OFF -DENABLE_SVE=OFF -DENABLE_SVE2=OFF \
		-DCONFIG_AV1_DECODER=0 -DENABLE_DOCS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTS=OFF \
		-DENABLE_TOOLS=OFF -DENABLE_TESTDATA=OFF
	grep -q '^#define HAVE_NEON 1' _build/config/aom_config.h || die "libaom without NEON"
	normalize_stage
	library_packages libaom
}
