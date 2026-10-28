# ngtcp2 1.25.0: QUIC, for curl's HTTP/3 (with nghttp3), the release, with
# its OpenSSL backend (libngtcp2_crypto_ossl, OpenSSL 3.5's QUIC TLS
# interface): CI's OpenSSL on arm64 (deps/recipes/openssl.sh), HaikuPorts'
# openssl3 on x86_64. HaikuPorts has no ngtcp2.
VERSION=1.25.0
SOURCE_URL=https://github.com/ngtcp2/ngtcp2/releases/download/v1.25.0/ngtcp2-1.25.0.tar.xz
SOURCE_SHA256=2a34d2484ba17847a5d11965704e9dd0fac4c6d8efc75ffe1ec7de66d8c6b6fb
SUMMARY="QUIC protocol library"
COPYRIGHT="2017-2026 ngtcp2 contributors"
LICENSE="MIT"
[[ $ARCH == arm64 ]] && REQUIRES="openssl"
fetch_source() { fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"; }
build() {
	configure_ac --enable-lib-only --disable-static --with-openssl \
		--without-gnutls --without-boringssl --without-wolfssl --without-picotls \
		OPENSSL_CFLAGS="-I$DEPS/develop/headers" \
		OPENSSL_LIBS="-L$DEPS/develop/lib -L$DEPS/lib -L$SYSROOT/boot/system/develop/lib -lssl -lcrypto"
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
}
