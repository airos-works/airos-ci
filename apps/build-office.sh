#!/usr/bin/env bash
# Build the five Office packages at the reviewed revisions in office.lock.json.
# Called under the image's architecture lock, after its SDK has been built.
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
ARCH=${1:?usage: build-office.sh ARCH OUTPUT_DIR}
OUT=${2:?output directory}
if [[ ${AIROS_LOCKED:-} != haiku-$ARCH ]]; then
	exec env AIROS_LOCKED=haiku-$ARCH flock -s "$AIROS_LOCKS/haiku-$ARCH.lock" "$0" "$@"
fi
. "$AIROS_SDK/$ARCH/env.sh"
W=$AIROS_WORK/office-$ARCH
mkdir -p "$W/sources" "$W/packages" "$OUT"
key=$({
	cat "$AIROS_CI/apps/office.lock.json" "$AIROS_CI/apps/build-app-packages.sh" \
		"$AIROS_CI/apps/build-office.sh" "$AIROS_CI/sdk/build-rust.sh" \
		"$AIROS_CI/sdk/targets/aarch64-unknown-haiku.json"
	echo "$HAIKU_SHA $ARCH ${RUST_TOOLCHAIN:-nightly-2026-09-15}"
	"${CROSS}gcc" --version
} | sha256sum | cut -d' ' -f1)
if [[ $(cat "$W/key" 2>/dev/null) != "$key" ]]; then
	while IFS=$'\t' read -r app repo commit; do
		source=$W/sources/$app
		[[ -d $source/.git ]] || git clone -q --no-checkout "$repo" "$source"
		git -C "$source" cat-file -e "$commit^{commit}" 2>/dev/null \
			|| git -C "$source" fetch -q origin "$commit"
		git -C "$source" checkout -q --detach --force "$commit"
		git -C "$source" clean -qfdx
	done < <(python3 - "$AIROS_CI/apps/office.lock.json" <<'PY'
import json, sys
for app, source in json.load(open(sys.argv[1])).items():
    print(app, source['repository'], source['commit'], sep='\t')
PY
)
	AIROS_ARCH=$ARCH APPS=$W/sources APPBUILD=$W/build \
		"$AIROS_CI/apps/build-app-packages.sh" "$W/packages" clipper wordcraft gridcraft deckcraft pdfcraft
	"$AIROS_CI/images/verify-office.sh" "$TOOLS/package/package" "$ARCH" "$W/packages"
	python3 - "$AIROS_CI/apps/office.lock.json" "$W/sources.json" "$HAIKU_SHA" "$key" "${RUST_TOOLCHAIN:-nightly-2026-09-15}" <<'PY'
import json, sys
json.dump({'applications': json.load(open(sys.argv[1])), 'sdk': sys.argv[3],
           'recipe_sha256': sys.argv[4], 'rust': sys.argv[5]},
          open(sys.argv[2], 'w'), indent=2)
PY
	echo "$key" > "$W/key"
fi
"$AIROS_CI/images/verify-office.sh" "$TOOLS/package/package" "$ARCH" "$W/packages"
for app in clipper wordcraft gridcraft deckcraft pdfcraft; do
	rm -f "$OUT/$app"-[0-9]*-"$ARCH".hpkg
	cp "$W/packages/$app"-[0-9]*-"$ARCH".hpkg "$OUT/"
done
cp "$W/sources.json" "$OUT/office-sources.json"
