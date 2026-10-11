#!/usr/bin/env python3
"""stage-image-libs.py PACKAGE_TOOL IMAGE_PACKAGES SDK_SYSTEM OUT ARCH NAME...

Stages the libraries an image has, for a program that should link those rather
than carry copies: for every NAME (a HaikuPorts package such as fontconfig),
the image's own package from IMAGE_PACKAGES (the files the image is made from)
and its devel package, extracted into OUT (a boot/system tree). Also staged:
the image packages that the staged libraries need in turn and the SDK
(SDK_SYSTEM, its boot/system) lacks, so the linker finds every library.

The devel package comes from IMAGE_PACKAGES when it has the same version, else
from HaikuPorts (deps/haikuports.py): its headers may be a little newer, so
its link names (libharfbuzz.so) are pointed at the image's library file. A
symbol the image's library lacks then fails the link instead of the program.

Links that name /boot/system are made relative inside OUT. OUT/packages.txt
lists the runtime packages staged; OUT/packages holds them (their provides
make the program's package requirements, apps/release-requires.py).
"""
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))


def run(*args, **kw):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, text=True, **kw).stdout


def package_name(file):
    return re.match(r"(.+?)-\d", os.path.basename(file)).group(1)


def main():
    tool, image, sdk_system, out, arch, names = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], \
        sys.argv[5], sys.argv[6:]
    files = sorted(f for f in os.listdir(image) if f.endswith(".hpkg"))
    by_name = {}
    for f in files:
        by_name.setdefault(package_name(f), []).append(os.path.join(image, f))
    owner = {}  # lib/<file> of a runtime package in the image -> package file

    def owner_of(soname):
        if not owner:
            for f in files:
                if f.endswith(("-source.hpkg",)) or re.search(r"_(devel|source|debuginfo|doc)-", f):
                    continue
                for entry in run(tool, "list", "-p", os.path.join(image, f)).splitlines():
                    if entry.startswith("lib/") and entry.count("/") == 1:
                        owner.setdefault(entry[4:], os.path.join(image, f))
        return owner.get(soname)

    if os.path.isdir(out):
        shutil.rmtree(out)
    os.makedirs(os.path.join(out, "packages"))
    runtime, devel = [], []
    for name in names:
        found = by_name.get(name)
        if not found:
            sys.exit(f"error: the image has no {name} package")
        runtime.append(found[-1])
        version = re.match(r".+?-(\d.*)-\w+\.hpkg$", os.path.basename(found[-1])).group(1)
        same = [f for f in by_name.get(name + "_devel", []) if f"-{version}-" in os.path.basename(f)]
        if same:
            devel.append(same[-1])
        else:
            fetched = run(sys.executable, os.path.join(HERE, "..", "deps", "haikuports.py"), "fetch",
                          "--no-deps", arch, name + "_devel").split()
            if not fetched:
                sys.exit(f"error: no {name}_devel in HaikuPorts")
            devel.append(fetched[-1])
    staged = set(runtime)
    for f in runtime + devel:
        run(tool, "extract", "-C", out, f)
    # What the staged libraries need that neither OUT nor the SDK has.
    lib = os.path.join(out, "lib")
    while True:
        missing = set()
        for name in os.listdir(lib):
            path = os.path.join(lib, name)
            if os.path.islink(path) or ".so" not in name:
                continue
            for needed in re.findall(r"\(NEEDED\).*\[(.*)\]", run("readelf", "-d", path)):
                if not any(os.path.exists(os.path.join(d, needed))
                           for d in (lib, os.path.join(sdk_system, "lib"))):
                    missing.add(needed)
        added = {owner_of(n) for n in missing} - {None} - staged
        if not added:
            break
        for f in sorted(added):
            print(f"  for {', '.join(sorted(n for n in missing if owner_of(n) == f))}: "
                  f"{os.path.basename(f)}")
            run(tool, "extract", "-C", out, f)
            staged.add(f)
    for f in sorted(staged):
        shutil.copy2(f, os.path.join(out, "packages"))
    pi = os.path.join(out, ".PackageInfo")
    if os.path.exists(pi):
        os.remove(pi)
    run(sys.executable, os.path.join(HERE, "fix-devel-links.py"), out)
    with open(os.path.join(out, "packages.txt"), "w") as f:
        f.write("".join(os.path.basename(p) + "\n" for p in sorted(staged)))
    print(f"{len(staged)} image packages and {len(devel)} devel packages in {out}")


if __name__ == "__main__":
    main()
