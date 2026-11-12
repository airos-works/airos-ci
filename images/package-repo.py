#!/usr/bin/env python3
"""package-repo.py: the package repository air/OS serves for an architecture
HaikuPorts has no repository of (arm64), so that HaikuDepot and pkgman can
install its packages (airos-works/haiku#118).

    package-repo.py build ARCH --haiku DIR --tools DIR --image-packages DIR
        --cache DIR --out DIR [--base-url URL]
        Writes the repository into OUT: repo.info, repo, repo.sha256,
        packages/*.hpkg and index.json (each file's size and SHA-256). It
        holds the packages of the build system's list
        (DIR/build/jam/repositories/HaikuPorts/ARCH), fetched from that list's
        build-packages server into CACHE (the bootstrap gcc, binutils, make,
        ...), but not
          - the source packages;
          - one the image (its system packages, --image-packages) has another
            build of: CI's icu74, ncurses6, freetype, noto, ... stay, and an
            update would replace them with the bootstrap ones;
          - one whose libraries or commands an image package of another
            name has (curl: CI's airos_curl has libcurl);
          - one that needs what neither the repository nor the image
            provides (freetype_devel 2.6.3 for the bootstrap FreeType).
        package_repo wants one vendor, so CI's own packages (vendor air/OS)
        are not in it.

    package-repo.py publish ARCH DIR [--repo OWNER/NAME] [--dry-run]
        Mirrors the repository in DIR to the GitHub release repo-ARCH, every
        file as an asset of its own name. airos-works/airos-website lays the
        assets out at https://airos.works/repo/ARCH/ (scripts/sync.py), the
        address in the images' repository configuration. index.json, which
        the website goes by, changes last, after everything it names is
        there; assets it no longer names are deleted after that.

    package-repo.py ci ARCH IMAGE_DIR [--repo OWNER/NAME] [--dry-run]
        After an image build (airos-works/haiku .github/workflows/
        airos-images.yml): "build" with the image's release (IMAGE_DIR/release,
        from release-feed.py extract: its packages, Haiku source and tools)
        into $AIROS_ARTIFACTS/repo/ARCH, then "publish".

The repository keeps the name HaikuPorts and its identifier, so the images'
configuration and cache files keep their names.
"""
import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import urllib.request

DEFAULT_BASE_URL = "https://airos.works/repo/{arch}"
SOURCE_SUFFIXES = ("_source", "_debuginfo")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def tool(tools, name):
    return os.path.join(tools, name, name)


def package_info(tools, path):
    """name, version, architecture, provides {name: [version]} and requires
    [(name, operator, version)] of a package."""
    output = subprocess.run([tool(tools, "package"), "list", "-i", path],
        check=True, stdout=subprocess.PIPE, text=True).stdout
    info = {}
    for key in ("name", "version", "architecture"):
        match = re.search(rf"(?m)^\s*{key}: (.*)$", output)
        info[key] = match.group(1).strip() if match else ""
    info["provides"] = {info["name"]: [info["version"].rsplit("-", 1)[0]]}
    for match in re.finditer(r"(?m)^\s*provides: ([^\s=<>]+)(?: = (\S+))?",
            output):
        info["provides"].setdefault(match.group(1), []).append(match.group(2))
    info["requires"] = re.findall(
        r"(?m)^\s*requires: ([^\s=<>!]+)\s*(?:([=<>!]=?)\s*(\S+))?", output)
    return info


def natural_key(text):
    return [(0, int(part), "") if part.isdigit() else (1, 0, part)
        for part in re.findall(r"\d+|[^\d]+", text)]


def version_key(version):
    """BPackageVersion order: major.minor.micro naturally, then a release
    over its ~pre-releases; the revision is not part of what is provided."""
    version = version.rsplit("-", 1)[0] if re.search(r"-\d+$", version) \
        else version
    version, _, pre = version.partition("~")
    return ([natural_key(part) for part in version.split(".", 2)],
        (1,) if not pre else (0, natural_key(pre)))


def satisfies(provided, operator, version):
    if not operator:
        return True
    if provided is None:
        return False
    a, b = version_key(provided), version_key(version)
    return {"==": a == b, "=": a == b, ">=": a >= b, ">": a > b,
        "<=": a <= b, "<": a < b, "!=": a != b}[operator]


def unprovided(info, provides):
    """The requirements of info nothing in provides meets."""
    return [f"{name}{operator}{version}"
        for name, operator, version in info["requires"]
        if not any(satisfies(v, operator, version)
            for v in provides.get(name, []))]


def repository_list(haiku, arch):
    """(server URL, [file name]) of the build system's HaikuPorts list."""
    path = os.path.join(haiku, "build", "jam", "repositories", "HaikuPorts",
        arch)
    sections = [[]]
    for line in open(path):
        line = line.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith(":"):
            sections.append([])
            line = line[1:].strip()
            if not line:
                continue
        sections[-1].append(line.rstrip(";").strip())
    # RemotePackageRepository NAME : ARCH : URL : ANY... : ARCH... : SOURCES
    url = sections[2][0]
    files = [f"{p}-any.hpkg" for p in sections[3] if p]
    files += [f"{p}-{arch}.hpkg" for p in sections[4] if p]
    return url, files


def package_name(file_name):
    return file_name.split("-", 1)[0]


def fetch(url, target):
    if os.path.isfile(target):
        return
    temporary = target + ".part"
    with urllib.request.urlopen(url, timeout=600) as answer, \
            open(temporary, "wb") as f:
        shutil.copyfileobj(answer, f)
    os.replace(temporary, target)


def command_build(args):
    arch = args.arch
    url, listed = repository_list(args.haiku, arch)
    image = {}
    for name in sorted(os.listdir(args.image_packages)):
        if name.endswith(".hpkg"):
            image[name] = package_info(args.tools,
                os.path.join(args.image_packages, name))
    image_names = {info["name"]: name for name, info in image.items()}

    os.makedirs(args.cache, exist_ok=True)
    infos = {}
    for file_name in listed:
        name = package_name(file_name)
        if name.endswith(SOURCE_SUFFIXES):
            continue
        if name in image_names and image_names[name] != file_name:
            print(f"left out: {file_name} (the image has "
                f"{image_names[name]})")
            continue
        target = os.path.join(args.cache, file_name)
        fetch(f"{url}/packages/{file_name}", target)
        info = package_info(args.tools, target)
        if name not in image_names:
            # its files would clash with the image's package of another
            # name that has them (curl: CI's airos_curl has libcurl)
            clash = sorted({f"{p} ({i['name']})" for i in image.values()
                for p in info["provides"]
                if p.startswith(("lib:", "cmd:")) and p in i["provides"]})
            if clash:
                print(f"left out: {file_name} (the image has "
                    f"{', '.join(clash)})")
                continue
        infos[file_name] = info
        if infos[file_name]["architecture"] not in (arch, "any"):
            sys.exit(f"{file_name} is for "
                f"{infos[file_name]['architecture']}, not {arch}")

    # leave out what cannot be installed, until nothing else drops out
    while True:
        provides = {}
        for info in list(infos.values()) + list(image.values()):
            for name, versions in info["provides"].items():
                provides.setdefault(name, []).extend(versions)
        dropped = {f: unprovided(i, provides) for f, i in infos.items()}
        dropped = {f: m for f, m in dropped.items() if m}
        if not dropped:
            break
        for file_name, missing in dropped.items():
            print(f"left out: {file_name} (nothing provides "
                f"{', '.join(missing)})")
            del infos[file_name]

    out = os.path.abspath(args.out)
    packages = os.path.join(out, "packages")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(packages)
    for file_name in infos:
        shutil.copy2(os.path.join(args.cache, file_name),
            os.path.join(packages, file_name))

    base_url = args.base_url or DEFAULT_BASE_URL.format(arch=arch)
    with open(os.path.join(out, "repo.info"), "w") as f:
        f.write(f'''name HaikuPorts
vendor "Haiku Project"
summary "HaikuPorts' {arch} build packages, served by air/OS"
priority 1
baseurl {base_url}
identifier tag:haikuports.org,2013:repositories/haikuports/master/{arch}
architecture {arch}
''')
    files = sorted(os.path.join(packages, f) for f in infos)
    subprocess.run([tool(args.tools, "package_repo"), "create", "-q",
        os.path.join(out, "repo.info"), *files], check=True, cwd=out)
    with open(os.path.join(out, "repo.sha256"), "w") as f:
        f.write(sha256(os.path.join(out, "repo")))

    index = {"arch": arch, "base_url": base_url, "files": []}
    for relative in ["repo.info", "repo", "repo.sha256"] \
            + [f"packages/{f}" for f in sorted(infos)]:
        path = os.path.join(out, relative)
        index["files"].append({"path": relative,
            "size": os.path.getsize(path), "sha256": sha256(path)})
    with open(os.path.join(out, "index.json"), "w") as f:
        json.dump(index, f, indent=1)
        f.write("\n")
    total = sum(e["size"] for e in index["files"])
    print(f"repository {arch}: {len(infos)} packages ({total / 1048576:.0f} "
        f"MiB), {base_url}")


# --- publish -----------------------------------------------------------------

def gh(*args, quiet=False):
    return subprocess.run(["gh", *args], check=True, text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL if quiet else None).stdout


def gh_json(*args, quiet=False):
    return json.loads(gh(*args, quiet=quiet))


def command_publish(args):
    directory = os.path.abspath(args.directory)
    index = json.load(open(os.path.join(directory, "index.json")))
    tag = f"repo-{args.arch}"
    try:
        release = gh_json("api", f"repos/{args.repo}/releases/tags/{tag}",
            quiet=True)
    except subprocess.CalledProcessError:
        release = None
    if release is None:
        notes = (f"The {args.arch} package repository of air/OS: HaikuPorts' "
            f"{args.arch} build packages and air/OS CI's {args.arch} builds. "
            f"Machines use it at {index['base_url']}/ (HaikuDepot, pkgman); "
            "this release holds its files for the website to serve. Written "
            "by airos-ci images/package-repo.py.")
        if args.dry_run:
            print(f"would create {tag}")
            release = {"id": 0, "assets": []}
        else:
            gh("release", "create", tag, "--repo", args.repo, "--prerelease",
                "--title", f"air/OS {args.arch} package repository",
                "--notes", notes, "--target", "master")
            release = gh_json("api", f"repos/{args.repo}/releases/tags/{tag}")

    def remote_digests():
        return {a["name"]: (a.get("digest") or "").removeprefix("sha256:")
            for a in release["assets"] if a.get("state") == "uploaded"}

    have = remote_digests()
    wanted = {os.path.basename(e["path"]): e for e in index["files"]}
    upload = [os.path.join(directory, e["path"]) for name, e in wanted.items()
        if have.get(name) != e["sha256"]]
    # the packages first, then the repository files, index.json last
    upload.sort(key=lambda p: (not p.endswith(".hpkg"), p))
    if args.dry_run:
        print(f"would upload {len(upload)} files to {tag}")
        return
    else:
        for start in range(0, len(upload), 20):
            gh("release", "upload", tag, "--repo", args.repo, "--clobber",
                *upload[start:start + 20])
        index_path = os.path.join(directory, "index.json")
        if have.get("index.json") != sha256(index_path):
            gh("release", "upload", tag, "--repo", args.repo, "--clobber",
                index_path)
        release = gh_json("api", f"repos/{args.repo}/releases/{release['id']}")
        have = remote_digests()
        for name, entry in wanted.items():
            if have.get(name) != entry["sha256"]:
                sys.exit(f"{name} did not reach {tag} intact")
    stale = [a for a in release["assets"]
        if a["name"] not in wanted and a["name"] != "index.json"]
    for asset in stale:
        if args.dry_run:
            print(f"would delete {asset['name']}")
        else:
            gh("api", "-X", "DELETE",
                f"repos/{args.repo}/releases/assets/{asset['id']}")
    print(f"{tag}: {len(upload)} files uploaded, {len(stale)} deleted, "
        f"{len(wanted)} in the repository")


def command_ci(args):
    release = os.path.join(os.path.abspath(args.image_dir), "release")
    if not os.path.isfile(os.path.join(release, "release.json")):
        print(f"{args.image_dir} has no release; no repository to publish")
        return
    read = lambda name: open(os.path.join(release, name)).read().strip()
    artifacts = os.environ.get("AIROS_ARTIFACTS", "/data2/airos/artifacts")
    cache = os.environ.get("AIROS_CACHE", "/data2/airos/cache")
    args.haiku = read("haiku-source")
    args.tools = read("tools")
    args.image_packages = os.path.join(release, "packages")
    args.cache = os.path.join(cache, "build-packages", args.arch)
    args.out = os.path.join(artifacts, "repo", args.arch)
    args.base_url = None
    command_build(args)
    args.directory = args.out
    command_publish(args)


def main():
    parser = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build")
    build.add_argument("arch")
    build.add_argument("--haiku", required=True)
    build.add_argument("--tools", required=True)
    build.add_argument("--cache", required=True)
    build.add_argument("--out", required=True)
    build.add_argument("--base-url")
    build.add_argument("--image-packages", required=True)
    publish = commands.add_parser("publish")
    publish.add_argument("arch")
    publish.add_argument("directory")
    publish.add_argument("--repo", default="airos-works/haiku")
    publish.add_argument("--dry-run", action="store_true")
    ci = commands.add_parser("ci")
    ci.add_argument("arch")
    ci.add_argument("image_dir")
    ci.add_argument("--repo", default="airos-works/haiku")
    ci.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    {"build": command_build, "publish": command_publish,
        "ci": command_ci}[args.command](args)


if __name__ == "__main__":
    main()
