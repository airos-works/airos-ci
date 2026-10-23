# GNU libiconv (arm64): character set conversion for Mail's message decoding
# (libiconv.so.2), the release HaikuPorts packages for x86_64, with the same
# extra encodings. The library only: no iconv command.
VERSION=1.18
SOURCE_URL=https://ftp.gnu.org/gnu/libiconv/libiconv-1.18.tar.gz
SOURCE_SHA256=3b08f5f4f9b4eb82f151a7040bfd6fe6c6fb922efe4b1659c66ea933276965e8
SUMMARY="GNU libiconv character set conversion library"
COPYRIGHT="2000-2024 Free Software Foundation, Inc."
LICENSE="GNU LGPL v2.1"
fetch_source() { fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"; }
build() {
	[[ $ARCH == arm64 ]] || die "libiconv is built for arm64 only (x86_64 has HaikuPorts')"
	configure_ac --enable-shared --disable-static --disable-nls --enable-extra-encodings
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
	rm -rf "$STAGE$PREFIX/bin"
}
