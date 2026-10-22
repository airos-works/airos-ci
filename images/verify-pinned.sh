#!/usr/bin/env bash
# verify-pinned.sh PACKAGE_TOOL ARCH PACKAGE_DIR SET
# Check the actual packages selected for an image of each application in
# apps/SET.lock.json, including each binary and its exact Deskbar link.
# Office/Media use their named folders; an entry can declare another folder.
set -euo pipefail
tool=${1:?usage: verify-pinned.sh PACKAGE_TOOL ARCH PACKAGE_DIR office|media|bridge|mail}
arch=${2:?architecture}
packages=${3:?package directory}
set=${4:?package set}
lock=$(cd "$(dirname "$0")/.." && pwd)/apps/$set.lock.json
work=$(mktemp -d "${TMPDIR:-/tmp}/$set-check.XXXXXX")
trap 'rm -rf "$work"' EXIT
shopt -s nullglob
entries=$(python3 - "$lock" "${set^}" <<'PY'
import json, sys
for name, source in json.load(open(sys.argv[1])).items():
    if source.get('binary'):
        print(name, source["binary"], source.get("menu_folder", sys.argv[2]), source.get("menu_name", source["binary"]), sep="\t")
PY
)
[[ -n $entries ]] || { echo "no applications in $lock" >&2; exit 1; }
while IFS=$'\t' read -r name binary folder menu; do
	files=("$packages/$name"-[0-9]*-"$arch".hpkg)
	[[ ${#files[@]} == 1 ]] || { echo "expected one $name package for $arch" >&2; exit 1; }
	file=${files[0]}
	"$tool" list -i "$file" | grep -q "^[[:space:]]*architecture: $arch\$"
	"$tool" list -p "$file" > "$work/paths"
	grep -qx "apps/$binary" "$work/paths"
	grep -qx "data/deskbar/menu/$folder/$menu" "$work/paths"
	if [[ $folder != Applications ]] && grep -qx "data/deskbar/menu/Applications/$menu" "$work/paths"; then
		echo "$name still has an Applications menu entry" >&2
		exit 1
	fi
	mkdir "$work/$name"
	"$tool" extract -C "$work/$name" "$file" "data/deskbar/menu/$folder/$menu"
	[[ $(readlink "$work/$name/data/deskbar/menu/$folder/$menu") == "../../../../apps/$binary" ]]
	echo "$folder: $binary ($arch)"
done <<< "$entries"
