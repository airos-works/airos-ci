# nghttp3 1.18.0: HTTP/3 framing and QPACK, for curl's HTTP/3 (with ngtcp2),
# the release; HaikuPorts' 1.2.0 is too old for it.
VERSION=1.18.0
SOURCE_URL=https://github.com/ngtcp2/nghttp3/releases/download/v1.18.0/nghttp3-1.18.0.tar.xz
SOURCE_SHA256=aad782c23d3f01bd4bb52c8bac7a553b631ef8115fd1612703df6183449fef19
SUMMARY="HTTP/3 library"
COPYRIGHT="2019-2026 nghttp3 contributors"
LICENSE="MIT"
fetch_source() { fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"; }
build() {
	configure_ac --enable-lib-only --disable-static
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
}
