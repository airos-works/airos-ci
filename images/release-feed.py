#!/usr/bin/env python3
"""release-feed.py: the System Updater feed of each target
(jmgasper/haiku docs/airos/SYSTEM-UPDATER.md).

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

The feed is served at http://<build server>/updates/TARGET/.
"""
import argparse
import datetime
import hashlib
import json
import os
import re
import shutil
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

    boot = []
    for file in args.boot_file:
        target = os.path.join(out, "boot", os.path.basename(file))
        os.makedirs(os.path.dirname(target), exist_ok=True)
        shutil.copy2(file, target)
        boot.append({"name": os.path.basename(file),
            "size": os.path.getsize(target), "sha256": sha256(target)})

    release["packages"] = entries
    release["payload"] = {"links": links}
    if args.haiku_source:
        # for "publish": where the Haiku commits are (not published)
        with open(os.path.join(out, "haiku-source"), "w") as f:
            f.write(os.path.abspath(args.haiku_source) + "\n")
    if boot:
        release["boot_files"] = boot
    write_json(os.path.join(out, "release.json"), release)
    total = sum(entry["size"] for entry in entries)
    print(f"release {release['id']}: {len(names)} packages and {len(optional)} "
        f"optional ones ({total / 1048576:.0f} MiB), {len(links)} payload links")


# --- publish ---------------------------------------------------------------

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


def package_changes(old, new):
    def versions(release):
        result = {}
        for package in release.get("packages", []):
            result.setdefault(package["name"], []).append(package["version"])
        return {name: ", ".join(sorted(v)) for name, v in result.items()}

    before, after = versions(old), versions(new)
    changes = []
    for name in sorted(set(before) | set(after)):
        if name in ("airos_release", "airos_payload"):
            continue
        if before.get(name) != after.get(name):
            changes.append({"name": name, "from": before.get(name, ""),
                "to": after.get(name, "")})
    return changes


def app_commits(old_manifest, new_manifest):
    """Commits of the pinned applications (Office, Media, Bridge, Mail)."""
    apps = []
    for key in ("office", "media", "bridge", "mail"):
        old, new = (old_manifest or {}).get(key) or {}, (new_manifest or {}).get(key) or {}
        if not isinstance(new, dict):
            continue
        for name, entry in sorted(new.items()):
            if not isinstance(entry, dict):
                continue
            before = (old.get(name) or {}) if isinstance(old, dict) else {}
            if entry.get("commit") and entry.get("commit") != before.get("commit"):
                apps.append({"name": entry.get("binary", name),
                    "from": before.get("commit", ""), "to": entry["commit"],
                    "repository": entry.get("repository", "")})
    return apps


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
        changes["packages"] = package_changes(previous, release)
        changes["apps"] = app_commits(previous.get("image_manifest"), manifest)
    else:
        changes["packages"] = []
        changes["haiku"] = []
    release["changes"] = changes
    if manifest:
        release["image_manifest"] = {key: manifest.get(key)
            for key in ("office", "media", "bridge", "mail", "recipe", "inputs")}

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
    args = parser.parse_args()
    {"extract": command_extract, "publish": command_publish}[args.command](args)


if __name__ == "__main__":
    main()
