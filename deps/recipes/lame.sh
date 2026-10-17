# LAME (arm64): the MP3 encoder library, for FFmpeg's libmp3lame encoder
# (rock5_ffmpeg, MediaConverter's MP3), the release HaikuPorts packages.
VERSION=3.100
SOURCE_URL=https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz
SOURCE_SHA256=ddfe36cab873794038ae2c1210557ad34857a4b6bdc515785d1da9e175b1da1e
SUMMARY="LAME MP3 encoder library"
COPYRIGHT="1998-2017 The LAME project"
LICENSE="GNU LGPL v2"
fetch_source() { fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"; }
build() {
	[[ $ARCH == arm64 ]] || die "LAME is built for arm64 only (x86_64 has HaikuPorts')"
	configure_ac --disable-static --enable-shared --disable-frontend --disable-decoder
	make -j"$JOBS"
	make install DESTDIR="$STAGE"
}
