#!/usr/bin/env bash
# verify-pinned.sh PACKAGE_TOOL ARCH PACKAGE_DIR SET
# Check the actual packages selected for an image of each application in
# apps/SET.lock.json (office, media), including their links in the Deskbar
# menu's folder of that name (Office, Media) and nowhere in Applications.
set -euo pipefail
tool=${1:?usage: verify-pinned.sh PACKAGE_TOOL ARCH PACKAGE_DIR office|media}
arch=${2:?architecture}
packages=${3:?package directory}
set=${4:?office or media}
lock=$(cd "$(dirname "$0")/.." && pwd)/apps/$set.lock.json
folder=${set^}
work=$(mktemp -d "${TMPDIR:-/tmp}/$set-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
shopt -s nullglob
entries=$(python3 - "$lock" <<'PY'
import json, sys
for name, source in json.load(open(sys.argv[1])).items():
    if source.get('binary'):
        print(f"{name}:{source['binary']}")
PY
)
[[ -n $entries ]] || { echo "no applications in $lock" >&2; exit 1; }
for entry in $entries; do
	IFS=: read -r name binary <<< "$entry"
	files=("$packages/$name"-[0-9]*-"$arch".hpkg)
	[[ ${#files[@]} == 1 ]] || { echo "expected one $name package for $arch" >&2; exit 1; }
	file=${files[0]}
	"$tool" list -i "$file" | grep -q "^[[:space:]]*architecture: $arch\$"
	"$tool" list -p "$file" > "$work/paths"
	grep -qx "apps/$binary" "$work/paths"
	grep -qx "data/deskbar/menu/$folder/$binary" "$work/paths"
	if grep -qx "data/deskbar/menu/Applications/$binary" "$work/paths"; then
		echo "$name still has an Applications menu entry" >&2
		exit 1
	fi
	mkdir "$work/$name"
	"$tool" extract -C "$work/$name" "$file" "data/deskbar/menu/$folder/$binary"
	[[ $(readlink "$work/$name/data/deskbar/menu/$folder/$binary") == "../../../../apps/$binary" ]]
	echo "$folder: $binary ($arch)"
done
