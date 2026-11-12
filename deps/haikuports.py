#!/usr/bin/env python3
"""Resolve and fetch HaikuPorts packages for an air/OS architecture.

    haikuports.py fetch ARCH REQ...            download what REQ needs; print the files
    haikuports.py fetch --no-deps ARCH PKG...  download exactly these packages (images
                                               add their dependencies themselves)
    haikuports.py fetch --have DIR ARCH REQ... count what the packages in DIR provide
                                               as there (repeatable): an image's own
                                               builds of HaikuPorts packages (qt6_base)
                                               are not fetched again as dependencies
    haikuports.py stage ARCH PREFIX REQ...     same, and extract them into PREFIX
                                               (a boot/system tree)
    haikuports.py current ARCH PREFIX REQ...   exit 0 if PREFIX was staged from
                                               exactly these files (its record)

REQ is a package name (curl_devel) or a resolvable (devel:libcurl >= 8).
What the Haiku base already provides (haiku, haiku_devel and the build
packages of the air/OS SDK) is never fetched. The repository index is cached
for a day in $AIROS_CACHE/haikuports/ARCH; packages are cached by file name.
Every run writes the resolved list (name-version-arch.hpkg and sha256) next
to the files, so a build records exactly which HaikuPorts packages it used.

Environment: AIROS_SDK, AIROS_CACHE (as lib/env.sh sets them), and
AIROS_SDK_NAME for an SDK other than the air/OS one of ARCH (x86_64-r1beta6,
sdk/build-release-sdk.sh), whose base is the packages in its HAIKU_PACKAGES.
"""
import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

BASE = os.environ.get("HAIKUPORTS_URL", "https://eu.hpkg.haiku-os.org/haikuports/master")
CACHE = os.environ.get("AIROS_CACHE", "/data2/airos/cache")
SDK = os.environ.get("AIROS_SDK", "/data1/airos/sdk")


def sdk_env(arch):
    env = {}
    # lib/sdk.sh exports AIROS_SDK_NAME for the architecture it was sourced for
    name = os.environ.get("AIROS_SDK_NAME") or arch
    if name != arch and not name.startswith(arch + "-"):
        name = arch
    for line in open(os.path.join(SDK, name, "env.sh")):
        m = re.match(r"(\w+)=(.*)", line.strip())
        if m:
            env[m.group(1)] = m.group(2)
    return env


def tool(arch, name):
    t = sdk_env(arch)["TOOLS"]
    return os.path.join(t, name, name) if os.path.isdir(os.path.join(t, name)) else os.path.join(t, name)


class Gone(Exception):
    """A package the cached index lists is no longer in the repository."""


def download(url, path, gone_ok=False):
    req = urllib.request.Request(url, headers={"User-Agent": "airos-ci"})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(req, timeout=120) as r, open(path + ".part", "wb") as f:
                while True:
                    chunk = r.read(1 << 20)
                    if not chunk:
                        break
                    f.write(chunk)
            os.rename(path + ".part", path)
            return
        except urllib.error.HTTPError as e:
            if e.code == 404 and gone_ok:
                raise Gone(url) from e
            print(f"warning: {url}: {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
        except Exception as e:  # noqa: BLE001 - retry any transfer error
            print(f"warning: {url}: {e}", file=sys.stderr)
            time.sleep(5 * (attempt + 1))
    sys.exit(f"error: cannot download {url}")


def parse_listing(text):
    pkgs, cur = [], None
    for line in text.splitlines():
        m = re.match(r"\t(name|version|architecture|provides|requires): (.*)", line)
        if not m:
            continue
        key, val = m.group(1), m.group(2).strip()
        if key == "name":
            cur = {"name": val, "provides": [], "requires": []}
            pkgs.append(cur)
        elif cur is not None:
            if key in ("provides", "requires"):
                cur[key].append(val)
            else:
                cur[key] = val
    return pkgs


def repository(arch, refresh=False):
    d = os.path.join(CACHE, "haikuports", arch)
    os.makedirs(d, exist_ok=True)
    repo, listing = os.path.join(d, "repo"), os.path.join(d, "repo.txt")
    if refresh or not os.path.exists(listing) or time.time() - os.path.getmtime(listing) > 86400:
        download(f"{BASE}/{arch}/current/repo", repo)
        text = subprocess.run([tool(arch, "package_repo"), "list", "-v", repo], check=True,
                              stdout=subprocess.PIPE, text=True, errors="replace").stdout
        with open(listing, "w") as f:
            f.write(text)
    return parse_listing(open(listing, errors="replace").read())


def vkey(v):
    return [(0, int(x)) if x.isdigit() else (1, x) for x in re.split(r"[._~-]", v or "0")]


def split(expr):
    # The compatible version is "compat >= X" in a .PackageInfo and
    # "(compatible >= X)" in package and repository listings.
    m = re.match(r"\s*([^<>=!\s]+)\s*(>=|<=|==|!=|<|>|=)?\s*([^\s]*)"
                 r"(?:\s+\(?compat(?:ible)?\s*>=\s*([^\s)]+)\)?)?", expr)
    return m.group(1), m.group(2), m.group(3) or None, m.group(4)


def satisfies(provide, require):
    pn, _, pv, pcompat = split(provide)
    rn, op, rv, _ = split(require)
    if pn != rn:
        return False
    if not op:
        return True
    if not pv:
        return False
    c = (vkey(pv) > vkey(rv)) - (vkey(pv) < vkey(rv))
    ok = {"==": c == 0, "=": c == 0, ">=": c >= 0, "<=": c <= 0, ">": c > 0, "<": c < 0, "!=": c != 0}[op]
    # An older version of the same compatible line (the base's zlib 1.3.1 for
    # lib:libz>=1.3.2) is taken as satisfying; jpeg 9 is no lib:libjpeg>=62.
    if not ok and op in (">=", ">") and pcompat and vkey(rv) >= vkey(pcompat) and c <= 0 \
            and vkey(rv)[:1] == vkey(pcompat)[:1]:
        return True
    # A provide compatible only back to its compatible version does not serve
    # a requirement for an older one: ffmpeg8's lib:libavcodec 62 (compatible
    # >= 62) is not airTime's lib:libavcodec>=60, ffmpeg6's 60 is.
    if ok and op in (">=", ">") and pcompat and vkey(rv) < vkey(pcompat):
        return False
    return ok


def installed_provides(arch):
    """Provides of the SDK's base: haiku, haiku_devel and the build packages
    (a release SDK: every package it was made from)."""
    env = sdk_env(arch)
    build = env["HAIKU_BUILD"]
    package = tool(arch, "package")
    provides = []
    if env.get("HAIKU_PACKAGES"):
        for name in sorted(os.listdir(env["HAIKU_PACKAGES"])):
            if name.endswith(".hpkg"):
                out = subprocess.run([package, "list", "-i", os.path.join(env["HAIKU_PACKAGES"], name)],
                                     check=True, stdout=subprocess.PIPE, text=True).stdout
                provides += re.findall(r"(?m)^\s*provides:\s*(.*)$", out)
        return provides
    pkgdir = os.path.join(build, "objects", "haiku", arch, "packaging", "packages")
    for name in ("haiku.hpkg", "haiku_devel.hpkg"):
        out = subprocess.run([package, "list", "-i", os.path.join(pkgdir, name)], check=True,
                             stdout=subprocess.PIPE, text=True).stdout
        provides += re.findall(r"(?m)^\s*provides:\s*(.*)$", out)
    for entry in os.listdir(os.path.join(build, "build_packages")):
        info = os.path.join(build, "build_packages", entry, ".PackageInfo")
        if os.path.exists(info):
            text = open(info).read()
            m = re.search(r"provides\s*\{(.*?)\}", text, re.S)
            if m:
                provides += [l.strip().strip('"') for l in m.group(1).splitlines() if l.strip()]
    return provides


def package_provides(directories, arch):
    """Provides of the packages (*.hpkg) in the given directories."""
    package = tool(arch, "package")
    provides = []
    for directory in directories:
        for name in sorted(os.listdir(directory)):
            if name.endswith(".hpkg"):
                out = subprocess.run([package, "list", "-i", os.path.join(directory, name)],
                                     check=True, stdout=subprocess.PIPE, text=True).stdout
                provides += re.findall(r"(?m)^\s*provides:\s*(.*)$", out)
    return provides


def resolve(arch, requirements, deps=True, have=()):
    pkgs = [p for p in repository(arch) if p.get("architecture") in (arch, "any")
            and not p["name"].endswith(("_debuginfo", "_source"))]
    # What the caller already has (an image's own qt6_base) is never fetched,
    # not even as a dependency of something that is: HaikuPorts' qt6_base came
    # in next to the patched one for qt6_declarative's lib:libqt6core==6.10.3,
    # and the image had two (airos-works/haiku#46).
    have = package_provides(have, arch) if have else []
    # The provides of the architecture's base are read only when a
    # requirement needs them: they come from the architecture's build
    # directory, which another job may be rebuilding (a fetch of named
    # packages, such as the arm64 images' architecture-neutral fonts and
    # certificates from the x86_64 repository, holds no lock on it, and a
    # half-written haiku.hpkg failed with "Invalid magic").
    base = None
    chosen, todo = {}, list(requirements)
    while todo:
        req = todo.pop(0)
        rn, op, rv, _ = split(req)
        if any(satisfies(p, req) for p in have):
            continue
        if not op and any(p["name"] == rn for p in pkgs) and rn not in chosen:
            candidates = [p for p in pkgs if p["name"] == rn]
        else:
            if base is None:
                base = installed_provides(arch)
            if any(satisfies(p, req) for p in base):
                continue
            if any(satisfies(prov, req) for c in chosen.values() for prov in c["provides"]):
                continue
            candidates = [p for p in pkgs if any(satisfies(prov, req) for prov in p["provides"])]
        if not candidates:
            sys.exit(f"error: nothing in HaikuPorts {arch} provides {req}")
        best = max(candidates, key=lambda p: vkey(p["version"]))
        if best["name"] in chosen:
            continue
        chosen[best["name"]] = best
        if deps:
            todo += best["requires"]
    return list(chosen.values())


def fetch(arch, requirements, deps=True, have=()):
    d = os.path.join(CACHE, "haikuports", arch, "packages")
    os.makedirs(d, exist_ok=True)
    # The index is cached for a day, and HaikuPorts removes a package's old
    # build when it publishes a new one: a listed file that is gone (404)
    # means the index is out of date, so it is read again once.
    for last in (False, True):
        files = []
        try:
            for p in sorted(resolve(arch, requirements, deps, have), key=lambda p: p["name"]):
                fname = f"{p['name']}-{p['version']}-{p['architecture']}.hpkg"
                path = os.path.join(d, fname)
                if not os.path.exists(path):
                    print(f"  download {fname}", file=sys.stderr)
                    download(f"{BASE}/{arch}/current/packages/{fname}", path, gone_ok=not last)
                files.append(path)
            return files
        except Gone as gone:
            print(f"warning: {gone} is gone from HaikuPorts: reading its index again", file=sys.stderr)
            repository(arch, refresh=True)


def main():
    args = sys.argv[1:]
    deps = True
    have = []
    while len(args) > 1 and args[1] in ("--no-deps", "--have"):
        if args[1] == "--no-deps":
            deps = False
            del args[1]
        else:
            if len(args) < 3:
                sys.exit(__doc__)
            have.append(args[2])
            del args[1:3]
    if len(args) < 2 or args[0] not in ("fetch", "stage", "current"):
        sys.exit(__doc__)
    cmd, arch = args[0], args[1]
    if cmd in ("stage", "current"):
        prefix, reqs = args[2], args[3:]
    else:
        prefix, reqs = None, args[2:]
    files = fetch(arch, reqs, deps, have)
    record = [{"file": os.path.basename(f), "sha256": hashlib.sha256(open(f, "rb").read()).hexdigest()}
              for f in files]
    if cmd == "current":
        # Staging again extracts every file anew, and the build's attribute
        # emulation gives each one a new entry in its attribute store.
        try:
            with open(os.path.join(prefix, ".haikuports.json")) as f:
                sys.exit(0 if json.load(f) == record else 1)
        except (OSError, ValueError):
            sys.exit(1)
    if prefix:
        os.makedirs(prefix, exist_ok=True)
        package = tool(arch, "package")
        for f in files:
            subprocess.run([package, "extract", "-C", prefix, f], check=True)
        for junk in (".PackageInfo",):
            p = os.path.join(prefix, junk)
            if os.path.exists(p):
                os.remove(p)
        with open(os.path.join(prefix, ".haikuports.json"), "w") as f:
            json.dump(record, f, indent=1)
    for f in files:
        print(f)


if __name__ == "__main__":
    main()
