#!/usr/bin/env python3
"""release-requires.py PACKAGE_TOOL PACKAGES_DIR [--skip DIR]... ELF...

For programs built against a Haiku release's SDK (sdk/build-release-sdk.sh):
prints the "requires" lines of the libraries the ELF files need from the
release, other than the haiku package's own (that "haiku >= ..." covers),
such as "lib:libcurl >= 4.8.0" and "lib:libscintilla >= 5.3.4", from the
provides of the packages the SDK was made from (PACKAGES_DIR). Libraries
that no package there has, or that a --skip DIR holds (the program's own,
carried in its package or its engine's, even when the release has a library
of that soname too), are left out.
"""
import os
import re
import subprocess
import sys


def run(*args):
    return subprocess.run(args, check=True, stdout=subprocess.PIPE, text=True).stdout


def main():
    tool, packages, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    carried, elves = set(), []
    while args:
        arg = args.pop(0)
        if arg == "--skip":
            directory = args.pop(0)
            if os.path.isdir(directory):
                carried.update(os.listdir(directory))
        else:
            elves.append(arg)
    needed = set()
    for elf in elves:
        needed.update(re.findall(r"\(NEEDED\).*\[(.*)\]", run("readelf", "-d", elf)))
    # Which package has lib/<file>, and what each package provides.
    owner, provides, versions = {}, {}, {}
    for name in sorted(os.listdir(packages)):
        if not name.endswith(".hpkg"):
            continue
        path = os.path.join(packages, name)
        info = run(tool, "list", "-i", path)
        package = re.search(r"(?m)^\s*name: (\S+)", info).group(1)
        versions[package] = re.search(r"(?m)^\s*version: (\S+)", info).group(1).rsplit("-", 1)[0]
        provides[package] = re.findall(r"(?m)^\s*provides: (lib:\S+) = (\S+)", info)
        for entry in run(tool, "list", "-p", path).splitlines():
            if entry.startswith("lib/") and entry.count("/") == 1:
                owner.setdefault(entry[4:], package)
    requires = set()
    for soname in sorted(needed - carried):
        package = owner.get(soname)
        if package is None or package == "haiku":
            continue
        stem = "lib:" + soname.split(".so", 1)[0]
        key = stem.replace("-", "_")
        for name, version in provides[package]:
            if name.replace("-", "_") == key:
                requires.add(f"{name} >= {version}")
                break
        else:
            requires.add(f"{package} >= {versions[package]}")
    for line in sorted(requires):
        print(line)


if __name__ == "__main__":
    main()
