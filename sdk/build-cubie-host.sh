#!/usr/bin/env bash
# Pinned Ubuntu amd64 tools for Cubie's AArch64 U-Boot, unpacked without root.
# Keeps the Linux cross compiler independent of Haiku's gcc-multilib packages.
set -euo pipefail
. "$(cd "$(dirname "$0")/.." && pwd)/lib/env.sh"
[[ $(uname -m) == x86_64 ]] || die "Cubie host tools currently require Linux x86_64"
R=$AIROS_TOOLCHAIN/cubie-host
mkdir -p "$R" "$AIROS_CACHE/cubie-host"
exec 9>"$AIROS_LOCKS/cubie-host.lock"
flock 9
key=$(sha256sum "$AIROS_CI/sdk/cubie-host.lock.json" | cut -d' ' -f1)
if [[ $(cat "$R/key" 2>/dev/null) != "$key" ]]; then
    rm -rf "$R/root"
    mkdir -p "$R/root"
    while IFS=$'\t' read -r url sha; do
        file=$AIROS_CACHE/cubie-host/${url##*/}
        if [[ ! -f $file ]]; then
            curl -fLsS --retry 3 -o "$file.part" "$url"
            mv "$file.part" "$file"
        fi
        echo "$sha  $file" | sha256sum -c --quiet
        dpkg-deb -x "$file" "$R/root"
    done < <(python3 - "$AIROS_CI/sdk/cubie-host.lock.json" <<'PY'
import json, sys
for p in json.load(open(sys.argv[1])):
    print(p['url'], p['sha256'], sep='\t')
PY
)
    echo "$key" > "$R/key"
fi
mkdir -p "$R/bin"
for tool in gcc ld ar objcopy objdump nm ranlib readelf strip; do
    binary=$tool
    [[ $tool != gcc ]] || binary=gcc-15
    cat > "$R/bin/aarch64-linux-gnu-$tool" <<EOF
#!/bin/sh
export LD_LIBRARY_PATH=$R/root/usr/lib/x86_64-linux-gnu\${LD_LIBRARY_PATH:+:\$LD_LIBRARY_PATH}
exec $R/root/usr/bin/aarch64-linux-gnu-$binary "\$@"
EOF
    chmod +x "$R/bin/aarch64-linux-gnu-$tool"
done
# Mesa needs the libclang-cpp linker name as well as the LLVM 18 runtime.
# Its other native development inputs are the provisioned host's packages.
N=$R/native
mkdir -p "$N/usr/lib/llvm-18/lib"
ln -sfn /usr/include "$N/usr/include"
ln -sfn /usr/lib/x86_64-linux-gnu "$N/usr/lib/x86_64-linux-gnu"
clang=/usr/lib/llvm-18/lib/libclang-cpp.so.18.1
[[ -f $clang ]] || die "install LLVM 18 and libclang-cpp18 (server/provision.sh)"
ln -sfn "$clang" "$N/usr/lib/llvm-18/lib/libclang-cpp.so"
cat > "$R/env.sh" <<EOF
export CROSS_COMPILE=$R/bin/aarch64-linux-gnu-
export HOSTCFLAGS="-I$R/root/usr/include -I$R/root/usr/include/x86_64-linux-gnu"
export HOSTLDFLAGS="-L$R/root/usr/lib/x86_64-linux-gnu -Wl,-rpath,$R/root/usr/lib/x86_64-linux-gnu"
export CUBIE_NATIVE_DEPS=\${CUBIE_NATIVE_DEPS:-$N}
EOF
libgcc=$("$R/bin/aarch64-linux-gnu-gcc" -print-libgcc-file-name)
[[ -f $libgcc ]] || die "cross compiler cannot find libgcc ($libgcc)"
"$R/bin/aarch64-linux-gnu-gcc" --version | head -n 1
