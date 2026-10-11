#!/usr/bin/env python3
"""fix-devel-links.py SYSTEM

In SYSTEM, a boot/system tree made by extracting packages on the build host:

- links that name /boot/system/... or a package's own directory,
  /packages/NAME/.self/... (packages make both), are made relative, so they
  lead into SYSTEM;
- a link in develop/lib that leads nowhere because its devel package belongs
  to a newer build (libharfbuzz.so -> libharfbuzz.so.0.61451.0 next to the
  image's libharfbuzz.so.0.61420.0) is pointed at the library file of that
  name in lib/, so programs link the image's library.

A link that matches no library is left dangling (gcc_syslibs_devel's
libsupc++.so is) and reported: a program that needs it fails to link.
"""
import os
import re
import sys


def main():
    system = os.path.abspath(sys.argv[1])
    for root, dirs, files in os.walk(system):
        for name in dirs + files:
            path = os.path.join(root, name)
            if os.path.islink(path):
                target = os.readlink(path)
                m = re.match(r"(/boot/system|/packages/[^/]+/\.self)/(.*)", target)
                if m:
                    os.remove(path)
                    os.symlink(os.path.relpath(os.path.join(system, m.group(2)), root), path)
    lib, develop = os.path.join(system, "lib"), os.path.join(system, "develop", "lib")
    if not os.path.isdir(develop):
        return
    for name in sorted(os.listdir(develop)):
        link = os.path.join(develop, name)
        if not os.path.islink(link) or os.path.exists(link):
            continue
        target = os.path.basename(os.readlink(link))
        stem = target[:target.index(".so") + 3] if ".so" in target else target
        candidates = [f for f in os.listdir(lib) if f.startswith(stem + ".")
                      and not os.path.islink(os.path.join(lib, f))] if os.path.isdir(lib) else []
        if len(candidates) != 1:
            print(f"warning: {name} names {target}; the image has {candidates or 'no ' + stem}")
            continue
        os.remove(link)
        os.symlink(os.path.relpath(os.path.join(lib, candidates[0]), develop), link)
        print(f"{name} -> the image's {candidates[0]}")


if __name__ == "__main__":
    main()
