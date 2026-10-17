# x265 (arm64): the H.265 encoder MediaConverter opens at run time
# (libx265.so.199), 3.5 as HaikuPorts builds it for x86_64 - one library
# that makes 8, 10 and 12-bit streams (the 10 and 12-bit variants linked into
# the 8-bit one) - with HaikuPorts' Haiku patches (patches/x265-3.5.patchset)
# and AArch64 flags for the HDR10+ part (patches/x265-3.5-aarch64-hdr10plus).
VERSION=3.5
SOURCE_URL=https://bitbucket.org/multicoreware/x265_git/downloads/x265_3.5.tar.gz
SOURCE_SHA256=e70a3335cacacbba0b3a20ec6fecd6783932288ebc8163ad74bcc9606477cae8
STAMP_EXTRA="patches:$(cat "$AIROS_CI"/deps/recipes/patches/x265-3.5* | sha256sum | cut -c1-16)"
SUMMARY="x265 H.265/HEVC encoder library (8, 10 and 12-bit)"
COPYRIGHT="2013-2021 MulticoreWare, Inc"
LICENSE="GNU GPL v2"
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
	patch -s -d "$SRC" -p1 < "$AIROS_CI/deps/recipes/patches/x265-3.5.patchset"
	patch -s -d "$SRC" -p1 < "$AIROS_CI/deps/recipes/patches/x265-3.5-aarch64-hdr10plus.patch"
}
build() {
	[[ $ARCH == arm64 ]] || die "x265 is built for arm64 only (x86_64 has HaikuPorts')"
	cd source
	local common=(-G Ninja -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" -DCMAKE_BUILD_TYPE=Release
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DGIT_ARCHETYPE=1 -DENABLE_CLI=OFF
		-DENABLE_ASSEMBLY=OFF -Wno-dev)
	# 12 and 10 bits as static libraries, linked into the 8-bit one
	cmake -S . -B build/12bit "${common[@]}" -DHIGH_BIT_DEPTH=ON -DMAIN12=ON \
		-DEXPORT_C_API=OFF -DENABLE_SHARED=OFF
	cmake --build build/12bit -j"$JOBS"
	cp build/12bit/libx265.a libx265_12b.a
	cmake -S . -B build/10bit "${common[@]}" -DHIGH_BIT_DEPTH=ON \
		-DEXPORT_C_API=OFF -DENABLE_SHARED=OFF -DENABLE_HDR10_PLUS=ON
	cmake --build build/10bit -j"$JOBS"
	cp build/10bit/libx265.a libx265_10b.a
	cp build/10bit/libhdr10plus.a libhdr10plus.a
	cmake -S . -B build/8bit "${common[@]}" -DENABLE_SHARED=ON \
		-DEXTRA_LIB="libx265_12b.a;libx265_10b.a;libhdr10plus.a" \
		-DEXTRA_LINK_FLAGS=-L"$PWD" -DLINKED_10BIT=ON -DLINKED_12BIT=ON \
		-DCMAKE_INSTALL_PREFIX=$PREFIX -DLIB_INSTALL_DIR=lib -DBIN_INSTALL_DIR=bin \
		-DINCLUDE_INSTALL_DIR=develop/headers
	cmake --build build/8bit -j"$JOBS"
	DESTDIR="$STAGE" cmake --install build/8bit
	rm -f "$STAGE$PREFIX"/lib/libx265.a
}
