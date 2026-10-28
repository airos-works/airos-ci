# OpenSSL 3.5.9 (an LTS release) for arm64, with the Haiku arm64 changes
# (patches/openssl-3.5.9.patchset, from airos-works/openssl airos-3.3.2: the
# haiku-aarch64 target, os-dep/haiku.h usable from assembler, and armcap's
# probe also catching SIGBUS, which kernels before 5c5d648906 sent for an
# undefined instruction). 3.5 for ngtcp2's OpenSSL QUIC backend, which
# curl's HTTP/3 uses. Shared and static: Burrow links libssl.a/libcrypto.a
# statically on arm64. x86_64 has HaikuPorts' openssl3 (3.5 as well).
VERSION=3.5.9
SOURCE_URL=https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
SOURCE_SHA256=603f5602e2eef00d77fbd429d34dcd5822bb301757a1bc9cdb24c670f1eb859a
STAMP_EXTRA="patches:$(sha256sum "$AIROS_CI/deps/recipes/patches/openssl-3.5.9.patchset" | cut -c1-16)"
SUMMARY="OpenSSL TLS and cryptography libraries"
COPYRIGHT="1998-2026 The OpenSSL Project Authors"
LICENSE="Apache v2"
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
	patch -s -d "$SRC" -p1 < "$AIROS_CI/deps/recipes/patches/openssl-3.5.9.patchset"
}
build() {
	local target
	case $ARCH in arm64) target=haiku-aarch64 ;; x86_64) target=haiku-x86_64 ;; esac
	CC=${CROSS}gcc CFLAGS="--sysroot=$SYSROOT -O2 -fPIC" LDFLAGS="--sysroot=$SYSROOT" \
		./Configure "$target" shared no-tests no-docs --prefix=$PREFIX --libdir=lib \
		--openssldir=$PREFIX/data/ssl
	make -j"$JOBS"
	make install_sw DESTDIR="$STAGE"
}
