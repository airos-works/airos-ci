# SVT-AV1 (arm64): the AV1 encoder MediaConverter opens at run time
# (libSvtAv1Enc.so.3), 3.0.2 as HaikuPorts' svt_av13 for x86_64, with its
# AArch64 NEON code and HaikuPorts' patch (patches/svt_av1-3.0.2.patchset).
VERSION=3.0.2
SOURCE_URL=https://gitlab.com/AOMediaCodec/SVT-AV1/-/archive/v3.0.2/SVT-AV1-v3.0.2.tar.bz2
SOURCE_SHA256=7548a380cd58a46998ab4f1a02901ef72c37a7c6317c930cde5df2e6349e437b
STAMP_EXTRA="patches:$(sha256sum "$AIROS_CI/deps/recipes/patches/svt_av1-3.0.2.patchset" | cut -c1-16)"
SUMMARY="SVT-AV1 AV1 encoder library"
COPYRIGHT="2019-2025 Alliance for Open Media, Intel Corporation, Netflix"
LICENSE="BSD (3-clause)"
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
	patch -s -d "$SRC" -p1 < "$AIROS_CI/deps/recipes/patches/svt_av1-3.0.2.patchset"
}
build() {
	[[ $ARCH == arm64 ]] || die "SVT-AV1 is built for arm64 only (x86_64 has HaikuPorts')"
	cmake_build -DBUILD_SHARED_LIBS=ON -DNATIVE=OFF -DUSE_CPUINFO=OFF \
		-DBUILD_APPS=OFF -DBUILD_DEC=OFF -DBUILD_TESTING=OFF -DCMAKE_POLICY_VERSION_MINIMUM=3.5
}
