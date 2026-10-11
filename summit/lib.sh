# Source from the summit/ scripts after lib/env.sh, with ARCH set and the
# summit-SDK_NAME lock held.
#
# AIROS_TARGET (lib/env.sh): airos, or a Haiku release (r1beta6) for a build
# that runs on a stock Haiku installation. SDK_NAME (x86_64, x86_64-r1beta6)
# names the SDK and every tree of the target: $AIROS_ROOT/summit/SDK_NAME,
# $AIROS_SRC/webkit-SDK_NAME, $AIROS_BUILD/webkit-SDK_NAME, gl/SDK_NAME.
#
# summit_sdk: a snapshot of the SDK_NAME SDK (sysroot with the GL stack laid
# over it, cross compiler, unwinder specs) in $SUMMIT_ROOT, so the engine
# build, which takes hours, does not hold the SDK's lock that image builds
# take to update it. Files are copied by content (rsync -c, no times): a new
# Haiku revision rewrites only the headers that changed, and the engine's
# ninja rebuilds only what includes them.
# Sets ARCH, TRIPLET, CROSS, SYSROOT, UNWIND_SPECS, HAIKU_RELEASE (empty for
# air/OS), HAIKU_REVISION, HAIKU_SHA and DEPS (the GL stack and app libraries
# of deps/build-deps.sh; a release's sysroot), and puts the host rc and xres
# on PATH.
#
# SYSLIBS (x86_64): a boot/system tree with the libraries of the image the
# engine runs on, which it links rather than carrying copies of them
# (SUMMIT_SYSTEM_LIBS; summit/build-deps.sh then builds only ICU 78, libzip
# and libepoxy). A second, older copy in Summit's processes breaks the
# system's add-ons loaded into them: the Media Kit's FFmpeg reader loads
# libass, which needs the system's Fontconfig, and with the engine's
# Fontconfig 2.15 it did not load at all (no video). A Haiku release's SDK
# has these libraries in its sysroot; for air/OS, summit_sdk stages them from
# the packages the image is made of ($HAIKU_BUILD/download) into
# $SUMMIT_ROOT/system. Empty for arm64, whose images have no HaikuPorts: the
# engine carries the jmgasper forks' builds, as the images' airos_* packages.

SDK_NAME=$(sdk_name "$ARCH")
SUMMIT_ROOT=$AIROS_ROOT/summit/$SDK_NAME
SUMMIT_SYSTEM_LIBS=(brotli curl expat fontconfig freetype harfbuzz lcms libexecinfo libjpeg_turbo
	libpng16 libpsl libwebp libxml2 libxslt nghttp2 openssl3 sqlite woff2)
if [[ $ARCH != x86_64 ]]; then
	SYSLIBS=
elif [[ $SDK_NAME == "$ARCH" ]]; then
	SYSLIBS=$SUMMIT_ROOT/system
else
	SYSLIBS=$SUMMIT_ROOT/sysroot/boot/system
fi

summit_sdk() {
	mkdir -p "$SUMMIT_ROOT"
	(
		flock -s 9
		[[ -f $AIROS_SDK/$SDK_NAME/env.sh ]] || die "no $SDK_NAME SDK; run sdk/build-sdk.sh $ARCH" \
			"(for a Haiku release: sdk/build-release-sdk.sh $ARCH ${AIROS_TARGET:-})"
		. "$AIROS_SDK/$SDK_NAME/env.sh"
		# with the GL stack (deps/build-gl.sh) laid over it
		local gl=()
		[[ ! -d $AIROS_ROOT/gl/$SDK_NAME/boot ]] || gl=("$AIROS_ROOT/gl/$SDK_NAME/")
		# group-writable, as the server's trees are (packages carry 0755)
		rsync -rlc --chmod=g+rwX --delete "$SYSROOT/" "${gl[@]}" "$SUMMIT_ROOT/sysroot/"
		rsync -rlc --chmod=g+rwX --delete "${CROSS%/bin/*}/" "$SUMMIT_ROOT/cross-tools/"
		cp "$UNWIND_SPECS" "$SUMMIT_ROOT/shared-unwinder.specs"
		# The host rc and xres (WebKit's Haiku resources) with their libraries
		# (a release SDK has its own copies: HOST_TOOLS).
		local tools=$SUMMIT_ROOT/host-tools.new tool lib
		rm -rf "$tools"
		if [[ -n ${HOST_TOOLS:-} ]]; then
			cp -a "$HOST_TOOLS" "$tools"
		else
			mkdir -p "$tools/bin" "$tools/lib"
			cp -L "$TOOLS/rc/rc" "$TOOLS/xres" "$tools/bin/"
			for lib in $(ldd "$TOOLS/rc/rc" "$TOOLS/xres" | awk '$3 ~ /objects\/linux\/lib/ {print $3}' | sort -u); do
				cp -L "$lib" "$tools/lib/"
			done
			for tool in "$tools"/bin/*; do
				patchelf --set-rpath '$ORIGIN/../lib' "$tool"
			done
		fi
		rsync -rlc --delete "$tools/" "$SUMMIT_ROOT/host-tools/"
		rm -rf "$tools"
		# x86_64 air/OS: the image's libraries (SYSLIBS), by content too.
		if [[ $ARCH == x86_64 && $SDK_NAME == "$ARCH" ]]; then
			[[ -d $HAIKU_BUILD/download ]] || die "no $HAIKU_BUILD/download: the image's packages"
			python3 "$AIROS_CI/lib/stage-image-libs.py" "$TOOLS/package/package" "$HAIKU_BUILD/download" \
				"$SYSROOT/boot/system" "$SYSLIBS.new" "$ARCH" "${SUMMIT_SYSTEM_LIBS[@]}" > "$SYSLIBS.log" \
				|| { tail -20 "$SYSLIBS.log"; die "staging the image's libraries failed (log: $SYSLIBS.log)"; }
			chgrp -R -h "$(stat -c %G "$SUMMIT_ROOT")" "$SYSLIBS.new"
			rsync -rlc --chmod=g+rwX --delete "$SYSLIBS.new/" "$SYSLIBS/"
			rm -rf "$SYSLIBS.new"
			tail -1 "$SYSLIBS.log"
		fi
		cat > "$SUMMIT_ROOT/sdk-env.sh" <<EOF
# snapshot of $AIROS_SDK/$SDK_NAME, made by summit/lib.sh
HAIKU_RELEASE=${HAIKU_RELEASE:-}
HAIKU_REVISION=$HAIKU_REVISION
HAIKU_SHA=$HAIKU_SHA
TRIPLET=$TRIPLET
CROSS=$SUMMIT_ROOT/cross-tools/bin/$TRIPLET-
SYSROOT=$SUMMIT_ROOT/sysroot
UNWIND_SPECS=$SUMMIT_ROOT/shared-unwinder.specs
EOF
	) 9>"$AIROS_LOCKS/haiku-$SDK_NAME.lock"
	. "$SUMMIT_ROOT/sdk-env.sh"
	# A release has no air/OS dependency prefix: only its sysroot.
	if [[ $SDK_NAME == "$ARCH" ]]; then
		DEPS=${DEPS:-$AIROS_ROOT/deps/$ARCH/boot/system}
	else
		DEPS=${DEPS:-$SYSROOT/boot/system}
	fi
	export PATH="$SUMMIT_ROOT/host-tools/bin:$PATH"
	mkdir -p "$AIROS_WORK"
	echo "SDK $HAIKU_REVISION ($SDK_NAME), snapshot in $SUMMIT_ROOT"
}
