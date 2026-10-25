# Node.js 22 (arm64): the runtime of Aurora (apps/build-app-packages.sh
# build_aurora), the release HaikuPorts packages as nodejs22 for x86_64, with
# its Haiku patches (patches/nodejs-22.23.3.patchset, HaikuPorts'
# net-libs/nodejs) and a cross build from Linux
# (patches/nodejs-22.23.3-airos-cross.patch): the Haiku settings apply to the
# target only, so the host tools (torque, mksnapshot for arm64, node_js2c) are
# built as on Linux; configure's libraries are the target's, and node_js2c
# links a host build of libuv; arm64 Haiku has no libexecinfo, so V8 prints
# no native stack trace.
# The cross patch also gives V8's CPU sampler the registers of an arm64
# Haiku signal context (sampler.cc has them for x86 only, and the profiler
# crashed reading garbage: VS Code's extension host, which profiles itself).
#
# Bundled: full ICU 78.3 (the version Node 22 is tested with; the release
# tarball named by tools/icu/current_ver.dep), and libuv and c-ares from
# Node's tree, built static with their CMake (upstream Haiku support).
# Shared: OpenSSL and nghttp2 (airos_openssl, airos_nghttp2) and Haiku's zlib.
# No npm, corepack or Node's own startup snapshot (node_mksnapshot would have
# to run on the build machine). As with HaikuPorts' build (its patch leaves
# GetCPUInfo out), os.cpus() is empty; os.availableParallelism() is right.
#
# Packaged as nodejs22 (cmd:node), like HaikuPorts', into the pool only: the
# images that carry Aurora install it (images/build-image.sh).
VERSION=22.23.3
PKG_REVISION=2
NO_PACKAGE=1
SOURCE_URL=https://nodejs.org/dist/v22.23.3/node-v22.23.3.tar.gz
SOURCE_SHA256=9436c81b284889303d39f5b8bd629bf19e790c665ccb94b4994aa87220d9799a
ICU_URL=https://github.com/unicode-org/icu/releases/download/release-78.3/icu4c-78.3-sources.tgz
ICU_SHA256=3a2e7a47604ba702f345878308e6fefeca612ee895cf4a5f222e7955fabfe0c0
STAMP_EXTRA="patches:$(cat "$AIROS_CI"/deps/recipes/patches/nodejs-22.23.3* | sha256sum | cut -c1-16)"
SUMMARY="Node.js JavaScript runtime"
fetch_source() {
	fetch_tarball "$SOURCE_URL" "$SOURCE_SHA256"
	patch -s -d "$SRC" -p1 < "$AIROS_CI/deps/recipes/patches/nodejs-22.23.3.patchset"
	patch -s -d "$SRC" -p1 < "$AIROS_CI/deps/recipes/patches/nodejs-22.23.3-airos-cross.patch"
}
build() {
	[[ $ARCH == arm64 ]] || die "Node.js is built for arm64 only (x86_64 has HaikuPorts' nodejs22)"
	local icu libs=$WORKDIR/nodejs22/libs pkg=$WORKDIR/nodejs22/package
	# V8 needs about 1.5 GB per compile job
	local jobs=$(( JOBS < ${NODE_JOBS:-12} ? JOBS : ${NODE_JOBS:-12} ))
	icu=$(fetch_file "$ICU_URL" "$ICU_SHA256")
	rm -rf "$libs"
	# libuv and c-ares for the target, libuv for the host tools
	cmake -S deps/uv -B _uv -G Ninja -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
		-DCMAKE_BUILD_TYPE=Release -DLIBUV_BUILD_SHARED=OFF -DLIBUV_BUILD_TESTS=OFF \
		-DLIBUV_BUILD_BENCH=OFF -DCMAKE_INSTALL_PREFIX="$libs/target" >/dev/null
	cmake --build _uv -j"$jobs" >/dev/null && cmake --install _uv >/dev/null
	cmake -S deps/cares -B _cares -G Ninja -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" \
		-DCMAKE_BUILD_TYPE=Release -DCARES_STATIC=ON -DCARES_SHARED=OFF -DCARES_STATIC_PIC=ON \
		-DCARES_BUILD_TOOLS=OFF -DCARES_BUILD_TESTS=OFF -DCMAKE_INSTALL_PREFIX="$libs/target" >/dev/null
	cmake --build _cares -j"$jobs" >/dev/null && cmake --install _cares >/dev/null
	env -u CC -u CXX -u AR -u RANLIB -u CPPFLAGS -u CFLAGS -u CXXFLAGS -u LDFLAGS \
		cmake -S deps/uv -B _uv-host -G Ninja -DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POSITION_INDEPENDENT_CODE=ON -DLIBUV_BUILD_SHARED=OFF -DLIBUV_BUILD_TESTS=OFF \
		-DLIBUV_BUILD_BENCH=OFF -DCMAKE_INSTALL_PREFIX="$libs/host" >/dev/null
	cmake --build _uv-host -j"$jobs" >/dev/null && cmake --install _uv-host >/dev/null

	local sys=$SYSROOT/boot/system
	CPPFLAGS= CFLAGS= CXXFLAGS= LDFLAGS= CC_host=gcc CXX_host=g++ AR_host=ar RANLIB_host=ranlib \
		PKG_CONFIG=false HOST_LIBUV_PREFIX="$libs/host" ./configure \
		--dest-os=haiku --dest-cpu=arm64 --cross-compiling --prefix=$PREFIX \
		--with-intl=full-icu --with-icu-source="$icu" \
		--shared-openssl --shared-openssl-includes="$DEPS/develop/headers" \
		--shared-openssl-libpath="$DEPS/develop/lib" \
		--shared-nghttp2 --shared-nghttp2-includes="$DEPS/develop/headers" \
		--shared-nghttp2-libpath="$DEPS/develop/lib" \
		--shared-zlib --shared-zlib-includes="$sys/develop/headers" --shared-zlib-libpath="$sys/develop/lib" \
		--shared-libuv --shared-libuv-includes="$libs/target/include" --shared-libuv-libpath="$libs/target/lib" \
		--shared-cares --shared-cares-includes="$libs/target/include" --shared-cares-libpath="$libs/target/lib" \
		--without-npm --without-corepack --without-node-snapshot --without-node-code-cache
	CPPFLAGS= CFLAGS= CXXFLAGS= LDFLAGS= make -C out -j"$jobs" BUILDTYPE=Release node

	rm -rf "$pkg"
	mkdir -p "$pkg/bin" "$pkg/documentation/packages/nodejs22" "$pkg/develop/headers/node" \
		"$pkg/data/licenses"
	install -m 0755 out/Release/node "$pkg/bin/node"
	${CROSS}strip --strip-unneeded "$pkg/bin/node"
	cp LICENSE "$pkg/data/licenses/Node.js"
	cp README.md CHANGELOG.md "$pkg/documentation/packages/nodejs22/"
	# headers for native add-ons, as HaikuPorts' nodejs22_devel has them
	python3 tools/install.py install --headers-only --dest-dir "$pkg/stage" --prefix / >/dev/null
	cp -a "$pkg/stage/include/node/." "$pkg/develop/headers/node/"
	rm -rf "$pkg/stage"
	cat > "$pkg/.PackageInfo" <<INFO
name nodejs22
version $VERSION-$PKG_REVISION
architecture arm64
summary "$SUMMARY"
description "Node.js $VERSION with full ICU, built by air/OS CI from the release tarball with HaikuPorts' patches and a cross build from Linux. No npm or corepack."
packager "air/OS CI"
vendor "air/OS"
urls { "https://nodejs.org/" }
copyrights { "Node.js contributors" "Joyent, Inc. and other Node contributors" }
licenses { "MIT" }
provides {
	nodejs22 = $VERSION
	cmd:node = $VERSION compat >= 22
}
requires {
	haiku >= r1~beta6
	airos_openssl
	airos_nghttp2
}
INFO
	local file=$AIROS_PACKAGES/arm64/nodejs22-$VERSION-$PKG_REVISION-arm64.hpkg
	with_lock packages-arm64 bash -c 'rm -f "$1"/nodejs22-[0-9]*-arm64.hpkg' _ "$AIROS_PACKAGES/arm64"
	"$TOOLS/package/package" create -q -C "$pkg" "$file"
	echo "package: $file"
}
