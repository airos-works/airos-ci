#!/usr/bin/env python3
"""release-feed.py: the System Updater feed of each target
(airos-works/haiku docs/airos/SYSTEM-UPDATER.md).

    release-feed.py extract IMAGE OUT --tools DIR [--boot-file FILE ...]
        Copies every package of the image's system/packages into OUT/packages
        and writes OUT/release.json: the release (from its airos_release
        package), each package's name, version, size and SHA-256, the links of
        its airos_payload package, and the extra boot files (the Pi's loader
        and boot archive). Run by images/build-image.sh on the image it built.

    release-feed.py publish TARGET IMAGE_DIR [--feed DIR] [--haiku-source DIR]
        Publishes the release that "extract" left in IMAGE_DIR/release into the
        feed (default $AIROS_ARTIFACTS/updates/TARGET), after the smoke test:
        packages/<sha256>/<file>, builds/<id>/update.json with the changes since
        the release before it, and index.json, newest first. Keeps the newest
        KEEP releases (default 12) and the packages they use.

        A package CI built again from the same sources (the Office apps after
        each Haiku change) has the same file name and contents as in the
        release before, but other file times and so another SHA-256: its entry
        lists the earlier SHA-256s as "equivalent", and System Updater keeps
        an installed copy instead of downloading it again.

The feed is served at http://<build server>/updates/TARGET/.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
import struct
import subprocess
import sys
import tempfile

BFS_GUID = "42465331-3BA3-10F1-802A-4861696B7521"
KEEP = int(os.environ.get("AIROS_UPDATE_KEEP", "12"))
MAX_COMMITS = 300


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def write_json(path, value):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    temporary = path + ".new"
    with open(temporary, "w") as f:
        json.dump(value, f, indent=1, ensure_ascii=False)
        f.write("\n")
    os.replace(temporary, path)


# --- extract ---------------------------------------------------------------

def bfs_partition(image):
    """(start, end) byte offsets of the image's BFS file system."""
    try:
        table = json.loads(subprocess.run(["sfdisk", "-J", image], check=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout)
    except (subprocess.CalledProcessError, ValueError):
        return 0, -1
    table = table["partitiontable"]
    sector = table.get("sectorsize", 512)
    for partition in table.get("partitions", []):
        kind = str(partition.get("type", "")).upper()
        if kind in ("EB", BFS_GUID):
            start = partition["start"] * sector
            return start, start + partition["size"] * sector
    return 0, -1


def bfs_shell(tools, image, commands):
    start, end = bfs_partition(image)
    argv = [os.path.join(tools, "bfs_shell", "bfs_shell")]
    if start or end >= 0:
        argv += ["--start-offset", str(start), "--end-offset", str(end)]
    argv.append(image)
    result = subprocess.run(argv, input="\n".join(commands) + "\nquit\n",
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
        errors="replace")
    if result.returncode != 0:
        sys.exit(f"bfs_shell failed on {image}:\n{result.stdout[-4000:]}")
    return result.stdout


def package_info(tools, path):
    output = subprocess.run([os.path.join(tools, "package", "package"), "list",
        "-i", path], check=True, stdout=subprocess.PIPE, text=True).stdout
    info = {}
    for key in ("name", "version", "architecture", "summary"):
        match = re.search(rf"(?m)^\s*{key}: (.*)$", output)
        info[key] = match.group(1).strip() if match else ""
    return info


def payload_links(tools, path):
    """The entries of the airos_payload package under data/airos/non-packaged."""
    with tempfile.TemporaryDirectory(prefix="airos-payload-") as directory:
        subprocess.run([os.path.join(tools, "package", "package"), "extract",
            "-C", directory, path], check=True, stdout=subprocess.DEVNULL)
        root = os.path.join(directory, "data", "airos", "non-packaged")
        links = []
        for top, dirs, files in os.walk(root):
            for name in sorted(files + [d for d in dirs
                    if os.path.islink(os.path.join(top, d))]):
                full = os.path.join(top, name)
                relative = os.path.relpath(full, root)
                if os.path.islink(full):
                    links.append({"path": relative, "type": "symlink",
                        "target": os.readlink(full)})
                else:
                    links.append({"path": relative, "type": "file"})
            dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(top, d))]
        return sorted(links, key=lambda link: link["path"])


def command_extract(args):
    out = os.path.abspath(args.out)
    packages = os.path.join(out, "packages")
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(packages)

    # system/packages, and the optional packages the Installer offers
    # (_packages_: the development tools), which an update brings up to date
    # where they are installed
    def list_packages(directory):
        listing = bfs_shell(args.tools, args.image, [f"ls myfs/{directory}"])
        return sorted(set(re.findall(r"\s(\S+\.hpkg)\s*$", listing, re.M)))

    names = list_packages("system/packages")
    if not names:
        sys.exit(f"no packages in {args.image}'s system/packages")
    optional = [name for name in list_packages("_packages_") if name not in names]
    bfs_shell(args.tools, args.image,
        [f"cp myfs/system/packages/{name} :{os.path.join(packages, name)}"
            for name in names]
        + [f"cp myfs/_packages_/{name} :{os.path.join(packages, name)}"
            for name in optional])

    release = None
    entries = []
    links = []
    for name in names + optional:
        path = os.path.join(packages, name)
        if not os.path.isfile(path):
            sys.exit(f"could not copy {name} out of {args.image}")
        info = package_info(args.tools, path)
        entry = {"name": info["name"], "version": info["version"],
            "file": name, "size": os.path.getsize(path), "sha256": sha256(path)}
        if name in optional:
            entry["optional"] = True
        entries.append(entry)
        if info["name"] == "airos_release":
            with tempfile.TemporaryDirectory(prefix="airos-release-") as d:
                subprocess.run([os.path.join(args.tools, "package", "package"),
                    "extract", "-C", d, path], check=True,
                    stdout=subprocess.DEVNULL)
                release = json.load(open(os.path.join(d, "data", "airos",
                    "release")))
        elif info["name"] == "airos_payload":
            links = payload_links(args.tools, path)
    if release is None:
        sys.exit(f"{args.image} has no airos_release package")

    # FILE or FILE=NAME: NAME is what the file is called on the boot
    # partition (the Pi's loader is haiku_loader.rpi, airos-loader.img there)
    boot = []
    for spec in args.boot_file:
        file, _, name = spec.partition("=")
        name = name or os.path.basename(file)
        target = os.path.join(out, "boot", name)
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(file, target)
        boot.append({"name": name, "size": os.path.getsize(target),
            "sha256": sha256(target)})

    release["packages"] = entries
    release["payload"] = {"links": links}
    if args.haiku_source:
        # for "publish": where the Haiku commits are (not published)
        with open(os.path.join(out, "haiku-source"), "w") as f:
            f.write(os.path.abspath(args.haiku_source) + "\n")
    # for "publish": the package tool, to compare packages with the release
    # before (not published)
    with open(os.path.join(out, "tools"), "w") as f:
        f.write(os.path.abspath(args.tools) + "\n")
    if boot:
        release["boot_files"] = boot
    write_json(os.path.join(out, "release.json"), release)
    total = sum(entry["size"] for entry in entries)
    print(f"release {release['id']}: {len(names)} packages and {len(optional)} "
        f"optional ones ({total / 1048576:.0f} MiB), {len(links)} payload links")


# --- publish ---------------------------------------------------------------

# file:atime, file:mtime, file:crtime and their nanoseconds
# (headers/os/package/hpkg/PackageAttributes.h)
TIME_ATTRIBUTES = {5, 6, 7, 8, 9, 10}
# package:version.major/minor/micro/revision/prerelease, package:provides and
# package:requires
VERSION_ATTRIBUTES = {22, 23, 24, 25, 36}
RESOLVABLE_ATTRIBUTES = {28, 29}
# Earlier builds an entry lists as equivalent. A machine whose copy is among
# them keeps it; CI makes 5 to 10 builds a day, so this reaches about a week.
MAX_EQUIVALENT = 64


def uleb128(data, position):
    value = shift = 0
    while True:
        byte = data[position]
        position += 1
        value |= (byte & 0x7f) << shift
        if not byte & 0x80:
            return value, position
        shift += 7


def hpkg_contents(tools, path, work):
    """What a package holds, without file times: its TOC and package
    attributes as trees of (attribute id, value, children), heap data as
    SHA-256 digests (headers/private/package/hpkg/HPKGDefsPrivate.h)."""
    plain = os.path.join(work, "plain.hpkg")
    subprocess.run([os.path.join(tools, "package", "package"), "recompress",
        "-q", "-0", path, plain], check=True)
    with open(plain, "rb") as f:
        data = f.read()
    os.unlink(plain)
    (magic, header_size, version, _total, _minor, compression, _chunk,
        _compressed, heap_size, attributes_length, attributes_strings_length,
        attributes_strings_count, _reserved, toc_length, toc_strings_length,
        toc_strings_count) = struct.unpack_from(">4sHHQHHIQQIIIIQQQ", data)
    if magic != b"hpkg" or version != 2 or compression != 0:
        raise ValueError(f"{path}: not an uncompressed version 2 package")
    heap = memoryview(data)[header_size:header_size + heap_size]
    if len(heap) != heap_size:
        raise ValueError(f"{path}: truncated")

    def section(start, length, strings_length, strings_count):
        raw = bytes(heap[start:start + length])
        strings = raw[:strings_length].split(b"\0")[:strings_count]
        position = strings_length

        def attributes():
            nonlocal position
            nodes = []
            while True:
                tag, position = uleb128(raw, position)
                if tag == 0:
                    return tuple(sorted(nodes, key=repr))
                tag -= 1
                ident, kind = tag & 0x7f, (tag >> 7) & 0x7
                has_children, encoding = (tag >> 10) & 1, (tag >> 11) & 3
                if kind in (1, 2):  # int, uint
                    size = 1 << encoding
                    value = int.from_bytes(raw[position:position + size], "big")
                    position += size
                elif kind == 3:  # string
                    if encoding == 1:
                        index, position = uleb128(raw, position)
                        value = strings[index]
                    else:
                        end = raw.index(b"\0", position)
                        value = raw[position:end]
                        position = end + 1
                elif kind == 4:  # raw data
                    size, position = uleb128(raw, position)
                    if encoding == 1:
                        offset, position = uleb128(raw, position)
                        value = hashlib.sha256(heap[offset:offset + size]).hexdigest()
                    else:
                        value = raw[position:position + size]
                        position += size
                else:
                    raise ValueError(f"{path}: attribute type {kind}")
                children = attributes() if has_children else ()
                if ident not in TIME_ATTRIBUTES:
                    nodes.append((ident, value, children))

        return attributes()

    attributes_start = heap_size - attributes_length
    return (section(attributes_start - toc_length, toc_length,
            toc_strings_length, toc_strings_count),
        section(attributes_start, attributes_length, attributes_strings_length,
            attributes_strings_count))


def without_symlink_attributes(nodes):
    """The TOC without the file attributes of symlinks. The Linux build keeps
    Haiku attributes in a side store keyed by inode, so a new symlink can
    inherit the BEOS:TYPE of a deleted file (amdnpu_firmwares had one in one
    build and not in the next); nothing reads a symlink's own attributes."""
    result = []
    for ident, value, children in nodes:
        if ident == 0:  # dir:entry
            symlink = (1, 2, ()) in children  # file:type B_HPKG_FILE_TYPE_SYMLINK
            children = tuple(child for child in
                without_symlink_attributes(children)
                if not (symlink and child[0] == 11))  # file:attribute
        result.append((ident, value, children))
    return tuple(result)


def same_files(tools, old, new):
    """Whether two packages hold the same files and package attributes, apart
    from file times, the attributes of symlinks and the version, provides and
    requires, which equivalent() judges."""
    with tempfile.TemporaryDirectory(prefix="release-feed-") as work:
        try:
            old_toc, old_attributes = hpkg_contents(tools, old, work)
            new_toc, new_attributes = hpkg_contents(tools, new, work)
        except (ValueError, IndexError, OSError, struct.error,
                subprocess.CalledProcessError) as error:
            print(f"cannot compare {os.path.basename(new)}: {error}")
            return False

    def rest(attributes):
        return tuple(node for node in attributes
            if node[0] not in VERSION_ATTRIBUTES | RESOLVABLE_ATTRIBUTES)

    def files(toc):
        # .PackageInfo is the package attributes as text, compared above
        return without_symlink_attributes(tuple(node for node in toc
            if node[:2] != (0, b".PackageInfo")))

    return (files(old_toc) == files(new_toc)
        and rest(old_attributes) == rest(new_attributes))


# --- versions, as BPackageVersion compares them ----------------------------

def natural_compare(a, b):
    """NaturalCompare() (ICU with numeric sorting) where its answer is
    certain, else None: runs of digits by value, letters without case."""
    ta = re.findall(r"\d+|[A-Za-z]+|.", a)
    tb = re.findall(r"\d+|[A-Za-z]+|.", b)
    for x, y in zip(ta, tb):
        if x == y:
            continue
        if x.isdigit() and y.isdigit() and int(x) != int(y):
            return -1 if int(x) < int(y) else 1
        if x.isalpha() and y.isalpha() and x.lower() != y.lower():
            return -1 if x.lower() < y.lower() else 1
        return None
    return (len(ta) > len(tb)) - (len(ta) < len(tb))


def compare_versions(a, b):
    """BPackageVersion::Compare() of two version strings
    (major.minor.micro~prerelease-revision), or None where unsure."""
    def parse(version):
        revision = 0
        match = re.fullmatch(r"(.*)-(\d+)", version)
        if match:
            version, revision = match.group(1), int(match.group(2))
        version, _, prerelease = version.partition("~")
        major, minor, micro = (version.split(".", 2) + ["", ""])[:3]
        return major, minor, micro, prerelease, revision

    if a == b:
        return 0
    pa, pb = parse(a), parse(b)
    for x, y in zip(pa[:3], pb[:3]):
        order = natural_compare(x, y)
        if order != 0:
            return order
    if pa[3] != pb[3]:
        if not pa[3] or not pb[3]:
            return 1 if not pa[3] else -1  # no pre-release is newer
        order = natural_compare(pa[3], pb[3])
        if order != 0:
            return order
    return (pa[4] > pb[4]) - (pa[4] < pb[4])


OPERATORS = {
    "<": lambda order: order < 0, "<=": lambda order: order <= 0,
    "==": lambda order: order == 0, "!=": lambda order: order != 0,
    ">=": lambda order: order >= 0, ">": lambda order: order > 0,
}


def satisfies(provided, operator, required):
    """Whether a provided version meets a requirement; False where unsure."""
    if not operator:
        return True
    if not provided:
        return False
    order = compare_versions(provided, required)
    return order is not None and OPERATORS[operator](order)


def resolvables(tools, path):
    """A package's version, provides [name, version] and requires
    [name, operator, version], from its package info."""
    output = subprocess.run([os.path.join(tools, "package", "package"), "list",
        "-i", path], check=True, stdout=subprocess.PIPE, text=True).stdout
    version = re.search(r"(?m)^\tversion: (\S+)", output)
    provides = [[m.group(1), m.group(2) or ""] for m in re.finditer(
        r"(?m)^\tprovides: (\S+)(?: = (\S+))?", output)]
    requires = [[m.group(1), m.group(2) or "", m.group(3) or ""]
        for m in re.finditer(r"(?m)^\trequires: ([^\s<>=!]+)"
            r"(?:(<=|>=|==|!=|<|>)(\S+))?", output)]
    return {"version": version.group(1) if version else "",
        "provides": provides, "requires": requires}


def weaker_requires(old, new):
    """Whether every requirement of the old build is the new build's or a
    weaker one (a lower minimum): what the release satisfies for the new
    build it satisfies for the old. CI stamps the Haiku it built against
    into some minimums (amdgpu_drm: haiku >= <that hrev>)."""
    def key(requirement):
        return (requirement[0], requirement[1])

    if sorted(map(key, old)) != sorted(map(key, new)):
        return False
    newer = {key(r): r[2] for r in new}
    for name, operator, version in old:
        if version == newer[(name, operator)]:
            continue
        if operator not in (">=", ">"):
            return False
        order = compare_versions(version, newer[(name, operator)])
        if order is None or order > 0:
            return False
    return True


def still_required(provides, release_requires, own_name):
    """Whether every versioned requirement of the release's other packages on
    what a build provides is met by that build's versions."""
    provided = {}
    for name, version in provides:
        provided.setdefault(name, []).append(version)
    for package, requirements in release_requires.items():
        if package == own_name:
            continue
        for name, operator, version in requirements:
            if name in provided and operator and not any(
                    satisfies(p, operator, version) for p in provided[name]):
                return False
    return True


def git_log(source, old, new):
    if not source or not old or not new or old == new:
        return [], 0
    try:
        output = subprocess.run(["git", "-C", source, "log", "--no-merges",
            "--format=%h%x09%cI%x09%s", f"{old}..{new}"], check=True,
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True).stdout
    except subprocess.CalledProcessError:
        return [], 0
    commits = []
    skipped = 0
    for line in output.splitlines():
        commit, date, subject = (line.split("\t", 2) + ["", ""])[:3]
        if "[skip ci]" in subject:
            skipped += 1
            continue
        commits.append({"commit": commit, "date": date, "subject": subject})
    more = max(0, len(commits) - MAX_COMMITS)
    return commits[:MAX_COMMITS], more + skipped


def package_changes(old, new, unchanged=()):
    """Packages whose versions changed, but for those that only CI's version
    stamp tells apart from the release before (equivalent ones)."""
    def versions(release):
        result = {}
        for package in release.get("packages", []):
            result.setdefault(package["name"], []).append(package["version"])
        return {name: ", ".join(sorted(v)) for name, v in result.items()}

    before, after = versions(old), versions(new)
    changes = []
    for name in sorted(set(before) | set(after)):
        if name in ("airos_release", "airos_payload") or name in unchanged:
            continue
        if before.get(name) != after.get(name):
            changes.append({"name": name, "from": before.get(name, ""),
                "to": after.get(name, "")})
    return changes


def app_commits(old_manifest, new_manifest):
    """Commits of the applications and build inputs pinned in each image."""
    apps = []
    for key in ("office", "media", "developer", "bridge", "mail"):
        old, new = (old_manifest or {}).get(key) or {}, (new_manifest or {}).get(key) or {}
        if not isinstance(new, dict):
            continue
        # The manifest records a package set with its SDK, recipe and application pins.
        new = new.get("applications", new)
        if isinstance(old, dict):
            old = old.get("applications", old)
        for name, entry in sorted(new.items()):
            if not isinstance(entry, dict):
                continue
            before = (old.get(name) or {}) if isinstance(old, dict) else {}
            if entry.get("commit") and entry.get("commit") != before.get("commit"):
                apps.append({"name": entry.get("binary", name),
                    "from": before.get("commit", ""), "to": entry["commit"],
                    "repository": entry.get("repository", "")})
    return apps


def mark_equivalents(tools, feed, staged, previous, release):
    """Lists in each package of the release the earlier builds of it that
    hold the same files ("equivalent"): System Updater keeps an installed
    copy that is one of them instead of downloading the package again.

    CI builds many packages again for every image although nothing in them
    changed but the build's stamp: other file times (the Office apps after
    each Haiku commit), a version that is the build's (airos_payload, 112 MiB,
    and the hrev of smbfs, userland_fs, haiku_datatranslators...), a minimum
    Haiku version that is the one built against (the DRM drivers). A build
    of another version counts only when the release still works with it: its
    requires are the new build's or weaker, and no versioned requirement of
    the release's other packages rules it out. Those of another file name are
    described in "equivalent_files" (file, version, provides), which the
    GitHub mirror needs to list one in place of the rebuild."""
    def staged_path(package):
        return os.path.join(staged, "packages", package["file"])

    def feed_path(package):
        return os.path.join(feed, "packages", package["sha256"], package["file"])

    infos = {}
    release_requires = {}
    for package in release["packages"]:
        info = resolvables(tools, staged_path(package))
        infos[package["file"]] = info
        release_requires.setdefault(package["name"], []).extend(
            info["requires"])

    by_file = {p["file"]: p for p in previous.get("packages", [])}
    by_name = {}
    for package in previous.get("packages", []):
        by_name.setdefault(package["name"], []).append(package)

    same = other_version = 0
    for package in release["packages"]:
        old = by_file.get(package["file"])
        if old is None and len(by_name.get(package["name"], [])) == 1:
            old = by_name[package["name"]][0]
        if old is None:
            continue
        info = infos[package["file"]]
        old_info = None
        if old["sha256"] != package["sha256"]:
            if not os.path.exists(feed_path(old)):
                continue
            old_info = resolvables(tools, feed_path(old))
            if (sorted(n for n, _ in old_info["provides"])
                    != sorted(n for n, _ in info["provides"])
                    or not weaker_requires(old_info["requires"],
                        info["requires"])
                    or not still_required(old_info["provides"],
                        release_requires, package["name"])
                    or not same_files(tools, feed_path(old),
                        staged_path(package))):
                continue
            if old["file"] == package["file"]:
                same += 1
            else:
                other_version += 1

        # the old entry's chain, and the old build itself
        files = {f["sha256"]: f for f in old.get("equivalent_files", [])}
        chain = list(old.get("equivalent", []))
        if old["sha256"] != package["sha256"]:
            chain.append(old["sha256"])
        equivalent, described = [], []
        for digest in chain:
            if digest == package["sha256"] or digest in equivalent:
                continue
            description = files.get(digest)
            if description is None and old["file"] != package["file"]:
                # an earlier build of the old entry's file name
                if old_info is None:
                    old_info = (resolvables(tools, feed_path(old))
                        if os.path.exists(feed_path(old)) else None)
                if old_info is None:
                    continue
                description = {"sha256": digest, "file": old["file"],
                    "version": old["version"],
                    "provides": old_info["provides"]}
            if description is not None:
                if description["file"] == package["file"]:
                    description = None
                elif not still_required(description["provides"],
                        release_requires, package["name"]):
                    continue
            equivalent.append(digest)
            if description is not None:
                described.append(description)
        equivalent = equivalent[-MAX_EQUIVALENT:]
        described = [d for d in described if d["sha256"] in equivalent]
        package.pop("equivalent", None)
        package.pop("equivalent_files", None)
        if equivalent:
            package["equivalent"] = equivalent
        if described:
            package["equivalent_files"] = described
    print(f"{same} packages built again with only other file times, "
        f"{other_version} with only another version")


def command_publish(args):
    image_dir = os.path.abspath(args.image_dir)
    staged = os.path.join(image_dir, "release")
    if not os.path.isfile(os.path.join(staged, "release.json")):
        print(f"{image_dir} has no release for System Updater; nothing to publish")
        return
    release = json.load(open(os.path.join(staged, "release.json")))
    if release.get("target") != args.target:
        sys.exit(f"the release is for {release.get('target')}, not {args.target}")

    feed = os.path.abspath(args.feed or os.path.join(
        os.environ.get("AIROS_ARTIFACTS", "/data2/airos/artifacts"), "updates",
        args.target))
    os.makedirs(os.path.join(feed, "packages"), exist_ok=True)
    index_path = os.path.join(feed, "index.json")
    index = json.load(open(index_path)) if os.path.exists(index_path) else {
        "format": 1, "target": args.target, "builds": []}
    builds = [b for b in index["builds"] if b["id"] != release["id"]]

    # the release before this one, for what changed
    previous = None
    for build in sorted(builds, key=lambda b: b["id"], reverse=True):
        if build["id"] < release["id"]:
            path = os.path.join(feed, build["manifest"])
            if os.path.exists(path):
                previous = json.load(open(path))
            break

    # earlier builds of the same files that only their file times tell apart
    tools = args.tools
    if not tools and os.path.exists(os.path.join(staged, "tools")):
        tools = open(os.path.join(staged, "tools")).read().strip()
    unchanged = set()
    if previous and tools:
        mark_equivalents(tools, feed, staged, previous, release)
        unchanged = {p["name"] for p in release["packages"]
            if p.get("equivalent") and any(o["sha256"] in p["equivalent"]
                or o["sha256"] == p["sha256"] for o in previous["packages"]
                if o["name"] == p["name"])}

    # the packages, once each
    for package in release["packages"]:
        source = os.path.join(staged, "packages", package["file"])
        relative = os.path.join("packages", package["sha256"], package["file"])
        target = os.path.join(feed, relative)
        if not os.path.exists(target):
            os.makedirs(os.path.dirname(target), exist_ok=True)
            temporary = target + ".new"
            try:
                os.link(source, temporary)
            except OSError:
                shutil.copy2(source, temporary)
            if sha256(temporary) != package["sha256"]:
                os.unlink(temporary)
                sys.exit(f"{source} changed since it was extracted")
            os.replace(temporary, target)
        package["url"] = "../../" + relative
    for boot in release.get("boot_files", []):
        source = os.path.join(staged, "boot", boot["name"])
        relative = os.path.join("boot", boot["sha256"], boot["name"])
        target = os.path.join(feed, relative)
        if not os.path.exists(target):
            os.makedirs(os.path.dirname(target), exist_ok=True)
            shutil.copy2(source, target + ".new")
            os.replace(target + ".new", target)
        boot["url"] = "../../" + relative

    # what changed
    manifest = None
    manifest_path = os.path.join(image_dir, "manifest.json")
    if os.path.exists(manifest_path):
        manifest = json.load(open(manifest_path))
    changes = {"previous": previous["id"] if previous else ""}
    source = args.haiku_source
    if not source and os.path.exists(os.path.join(staged, "haiku-source")):
        source = open(os.path.join(staged, "haiku-source")).read().strip()
    if previous:
        commits, more = git_log(source,
            previous.get("haiku", {}).get("commit"),
            release.get("haiku", {}).get("commit"))
        changes["haiku"] = commits
        changes["haiku_more"] = more
        changes["packages"] = package_changes(previous, release, unchanged)
        changes["apps"] = app_commits(previous.get("image_manifest"), manifest)
    else:
        changes["packages"] = []
        changes["haiku"] = []
    release["changes"] = changes
    if manifest:
        release["image_manifest"] = {key: manifest.get(key)
            for key in ("office", "media", "developer", "bridge", "mail", "recipe", "inputs")}

    relative = os.path.join("builds", release["id"], "update.json")
    write_json(os.path.join(feed, relative), release)
    entry = {
        "id": release["id"], "version": release["version"],
        "built": release.get("built", ""), "haiku": release.get("haiku", {}),
        "manifest": relative,
        "manifest_sha256": sha256(os.path.join(feed, relative)),
        "size": sum(p["size"] for p in release["packages"]
            if not p.get("optional")),
        "changes": {k: v for k, v in changes.items() if k != "apps"},
    }
    builds.append(entry)
    builds.sort(key=lambda b: b["id"], reverse=True)

    # keep the newest releases and what they use
    removed = builds[KEEP:]
    builds = builds[:KEEP]
    for build in removed:
        shutil.rmtree(os.path.join(feed, "builds", build["id"]),
            ignore_errors=True)
    used = set()
    for build in builds:
        path = os.path.join(feed, build["manifest"])
        if os.path.exists(path):
            for package in json.load(open(path)).get("packages", []):
                used.add(package["sha256"])
            for boot in json.load(open(path)).get("boot_files", []):
                used.add(boot["sha256"])
    for kind in ("packages", "boot"):
        directory = os.path.join(feed, kind)
        if not os.path.isdir(directory):
            continue
        for digest in os.listdir(directory):
            if digest not in used:
                shutil.rmtree(os.path.join(directory, digest), ignore_errors=True)

    index["builds"] = builds
    index["updated"] = datetime.datetime.now(datetime.timezone.utc).isoformat(
        timespec="seconds")
    write_json(index_path, index)
    print(f"published {release['id']} to {feed} ({len(builds)} releases)")


def main():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    extract = commands.add_parser("extract")
    extract.add_argument("image")
    extract.add_argument("out")
    extract.add_argument("--tools", required=True,
        help="the Haiku build's host tools (objects/linux/<arch>/release/tools)")
    extract.add_argument("--boot-file", action="append", default=[])
    extract.add_argument("--haiku-source")
    publish = commands.add_parser("publish")
    publish.add_argument("target")
    publish.add_argument("image_dir")
    publish.add_argument("--feed")
    publish.add_argument("--haiku-source")
    publish.add_argument("--tools",
        help="host tools with the package tool (default: those of extract)")
    args = parser.parse_args()
    {"extract": command_extract, "publish": command_publish}[args.command](args)


if __name__ == "__main__":
    main()
