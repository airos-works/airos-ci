#!/usr/bin/env bash
# build-pinned.sh SET ARCH OUTPUT_DIR
#
# Build the packages of one Deskbar folder at the reviewed revisions in
# apps/SET.lock.json: office (Clipper, WordCraft, GridCraft, DeckCraft,
# PdfCraft), media (PhotoCraft, LightCraft), or bridge (Proton Mail Bridge). An entry with a "binary" is an
# application; one without is a source the applications build with
# (craft-fonts). Called under the image's architecture lock, after its SDK has
# been built. Copies the packages and SET-sources.json (the pins, for the
# image manifest) to OUTPUT_DIR.
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
SET=${1:?usage: build-pinned.sh office|media|bridge ARCH OUTPUT_DIR}
ARCH=${2:?architecture}
OUT=${3:?output directory}
LOCK=$AIROS_CI/apps/$SET.lock.json
[[ -f $LOCK ]] || die "no $LOCK"
if [[ ${AIROS_LOCKED:-} != haiku-$ARCH ]]; then
	exec env AIROS_LOCKED=haiku-$ARCH flock -s "$AIROS_LOCKS/haiku-$ARCH.lock" "$0" "$@"
fi
. "$AIROS_SDK/$ARCH/env.sh"
W=$AIROS_WORK/$SET-$ARCH
mkdir -p "$W/sources" "$W/packages" "$OUT"
# name, repository, commit, release branch, source directory, binary of each entry
pins=$(python3 - "$LOCK" <<'PY'
import json, sys
for name, source in json.load(open(sys.argv[1])).items():
    print(name, source['repository'], source['commit'], source.get('branch', 'main'), source.get('source_directory', name), source.get('binary', ''), sep='\t')
PY
)
apps=($(awk -F '\t' '$6 != "" { print $1 }' <<< "$pins"))
key=$({
	cat "$LOCK" "$AIROS_CI/apps/build-app-packages.sh" \
		"$AIROS_CI/apps/build-pinned.sh" "$AIROS_CI/sdk/build-rust.sh" \
		"$AIROS_CI/sdk/targets/aarch64-unknown-haiku.json"
	echo "$HAIKU_SHA $ARCH ${RUST_TOOLCHAIN:-nightly-2026-09-15}"
	"${CROSS}gcc" --version
} | sha256sum | cut -d' ' -f1)
if [[ $(cat "$W/key" 2>/dev/null) != "$key" ]]; then
	while IFS=$'\t' read -r name repo commit branch directory binary; do
		source=$W/sources/$directory
		[[ -d $source/.git ]] || git clone -q --no-checkout "$repo" "$source"
		git -C "$source" cat-file -e "$commit^{commit}" 2>/dev/null \
			|| git -C "$source" fetch -q origin "$commit"
		# A pin must be on the declared release branch (main by default).
		git -C "$source" fetch -q origin "$branch"
		git -C "$source" merge-base --is-ancestor "$commit" FETCH_HEAD \
			|| die "$name: the pin $commit is not on $repo $branch"
		git -C "$source" checkout -q --detach --force "$commit"
		git -C "$source" clean -qfdx
	done <<< "$pins"
	AIROS_ARCH=$ARCH APPS=$W/sources APPBUILD=$W/build \
		"$AIROS_CI/apps/build-app-packages.sh" "$W/packages" "${apps[@]}"
	"$AIROS_CI/images/verify-pinned.sh" "$TOOLS/package/package" "$ARCH" "$W/packages" "$SET"
	python3 - "$LOCK" "$W/sources.json" "$HAIKU_SHA" "$key" "${RUST_TOOLCHAIN:-nightly-2026-09-15}" <<'PY'
import json, sys
json.dump({'applications': json.load(open(sys.argv[1])), 'sdk': sys.argv[3],
           'recipe_sha256': sys.argv[4], 'rust': sys.argv[5]},
          open(sys.argv[2], 'w'), indent=2)
PY
	echo "$key" > "$W/key"
fi
"$AIROS_CI/images/verify-pinned.sh" "$TOOLS/package/package" "$ARCH" "$W/packages" "$SET"
for app in "${apps[@]}"; do
	rm -f "$OUT/$app"-[0-9]*-"$ARCH".hpkg
	cp "$W/packages/$app"-[0-9]*-"$ARCH".hpkg "$OUT/"
done
cp "$W/sources.json" "$OUT/$SET-sources.json"
