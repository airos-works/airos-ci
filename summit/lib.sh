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

SDK_NAME=$(sdk_name "$ARCH")
SUMMIT_ROOT=$AIROS_ROOT/summit/$SDK_NAME

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
