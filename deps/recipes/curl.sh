# curl 8.23.0 with HTTP/3 (ngtcp2 and nghttp3 on OpenSSL 3.5's QUIC
# interface), HTTP/2 (nghttp2), OpenSSL and zlib, and the CA bundle of
# HaikuPorts' ca_root_certificates package; the release (the Haiku
# SOCK_NONBLOCK change of airos-works/curl airos-8.10.1 is no longer needed:
# the kernel has done it since September).
#
# arm64: the image's libcurl, packaged as airos_curl.
# x86_64: in place of HaikuPorts' curl, whose libcurl has no HTTP/3 (Summit
# issue 119): built with what HaikuPorts' links besides (libpsl, libssh2;
# deps/haikuports-x86_64.txt has their devel packages) and packaged under its
# name with its provides and a later revision, so the x86_64 image takes it
# (the tree's CI UserBuildConfig) and everything that requires curl or
# libcurl gets it. Its headers go into DEPS for the app builds.
VERSION=8.23.0
SOURCE_URL=https://curl.se/download/curl-8.23.0.tar.xz
SOURCE_SHA256=8dadd7d2536a314f982ad05a651b713f426bf7d02cc2c76cffb9796f2218e6c5
SUMMARY="libcurl URL transfer library"
COPYRIGHT="1996-2026 Daniel Stenberg and curl contributors"
LICENSE="MIT"
if [[ $ARCH == arm64 ]]; then
	REQUIRES="openssl nghttp2 ngtcp2 nghttp3"
else
	NO_PACKAGE=1
fi
fetch_source() { fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"; }
build() {
	local extra
	if [[ $ARCH == x86_64 ]]; then
		extra="--with-libpsl --with-libssh2"
	else
		extra="--without-libpsl --without-libssh2"
	fi
	configure_ac --enable-shared --disable-static --with-openssl --with-nghttp2 \
		--with-ngtcp2 --with-nghttp3 --with-zlib $extra \
		--without-brotli --without-zstd --without-libidn2 --disable-ldap \
		--disable-manual --disable-docs \
		--with-ca-bundle=/boot/system/data/ssl/CARootCertificates.pem --without-ca-path \
		LIBS=-lnetwork
	grep -q '^#define USE_NGTCP2 1' lib/curl_config.h || die "curl without ngtcp2 (HTTP/3)"
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
	[[ $ARCH == x86_64 ]] || return 0

	local root=$STAGE$PREFIX pkg=$WORKDIR/curl/package
	rm -rf "$pkg"
	mkdir -p "$pkg/bin" "$pkg/lib" "$pkg/data/licenses"
	cp "$root/bin/curl" "$pkg/bin/"
	[[ -f $root/bin/wcurl ]] && cp "$root/bin/wcurl" "$pkg/bin/"
	cp -a "$root"/lib/libcurl.so.4* "$pkg/lib/"
	${CROSS}strip --strip-debug "$pkg/bin/curl" "$pkg"/lib/libcurl.so.4.*
	cp COPYING "$pkg/data/licenses/curl"
	cat > "$pkg/.PackageInfo" <<INFO
name			curl
version			$VERSION-2
architecture	x86_64
summary			"A client-side URL transfer utility"
description		"curl $VERSION with HTTP/3 (ngtcp2, nghttp3), built by air/OS CI from $SOURCE_URL (sha256 $SOURCE_SHA256), with what HaikuPorts' curl links besides; it takes the place of HaikuPorts' curl, whose libcurl has no HTTP/3."
packager		"air/OS CI"
vendor			"air/OS"
copyrights {
	"$COPYRIGHT"
}
licenses {
	"MIT"
}
provides {
	curl = $VERSION
	cmd:curl = $VERSION compat >= 7.16
	cmd:wcurl = $VERSION compat >= 7.16
	lib:libcurl = 4.8.0 compat >= 4
}
requires {
	haiku >= r1~beta6
	ca_root_certificates
	lib:libnghttp2
	lib:libnghttp3
	lib:libngtcp2
	lib:libngtcp2_crypto_ossl
	lib:libssh2
	lib:libssl >= 3
	lib:libz
	lib:libpsl
}
INFO
	check_shared_unwinder "$pkg"/lib/libcurl.so.4.*
	system_package "$pkg"
}
