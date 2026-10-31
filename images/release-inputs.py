#!/usr/bin/env python3
"""release-inputs.py: what jam needs to make a release image System Updater
can update (airos-works/haiku tools/airos/ci/UserBuildConfig,
docs/airos/SYSTEM-UPDATER.md).

    release-inputs.py OUT --id ID --target TARGET --arch ARCH --feed URL
        --haiku-revision REV --haiku-commit SHA --recipe-commit SHA
        [--tree TOKENS=DIR ...]

writes into OUT:
  release         the release file the airos_release package installs as
                  /boot/system/data/airos/release (JSON)
  airos_release   the package info templates jam builds the release's two
  airos_payload   packages from
  files.jam       one AirosCIFile or AirosCISymlink per file of each --tree,
                  TOKENS being its image directory ("system non-packaged lib"),
                  for AIROS_CI_FILES

The release id starts with the build time (20261026-0915-hrev...), which is
also the packages' version (20261026.0915).
"""
import argparse
import datetime
import json
import os
import re
import sys


def jam_quote(token):
    if not token or re.search(r'[\s";:\\$]', token):
        return '"' + token.replace('\\', '\\\\').replace('"', '\\"') + '"'
    return token


def package_info(name, version, arch, summary, description, provides):
    return f'''name			{name}
version			{version}-1
architecture	{arch}
summary			"{summary}"
description		"{description}"
packager		"air/OS CI <https://github.com/airos-works/airos-ci>"
vendor			"air/OS"
copyrights {{
	"2026 air/OS contributors"
}}
licenses {{
	"MIT"
}}
provides {{
	{provides} = {version}
}}
'''


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("out")
    parser.add_argument("--id", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--arch", required=True)
    parser.add_argument("--feed", required=True)
    parser.add_argument("--haiku-revision", required=True)
    parser.add_argument("--haiku-commit", required=True)
    parser.add_argument("--recipe-commit", default="unknown")
    parser.add_argument("--tree", action="append", default=[])
    args = parser.parse_args()

    match = re.match(r"^(\d{8})-(\d{4})-", args.id)
    if not match:
        sys.exit(f"release id {args.id!r} does not start with the build time")
    version = f"{match.group(1)}.{match.group(2)}"
    built = datetime.datetime.strptime(match.group(1) + match.group(2),
        "%Y%m%d%H%M").replace(tzinfo=datetime.timezone.utc)

    os.makedirs(args.out, exist_ok=True)
    release = {
        "format": 1,
        "id": args.id,
        "version": version,
        "target": args.target,
        "arch": args.arch,
        "built": built.isoformat(timespec="seconds"),
        "haiku": {"revision": args.haiku_revision, "commit": args.haiku_commit},
        "recipe": {"commit": args.recipe_commit},
        "feed": args.feed,
    }
    with open(os.path.join(args.out, "release"), "w") as f:
        json.dump(release, f, indent=1)
        f.write("\n")

    when = built.strftime("%d %B %Y, %H:%M").lstrip("0")
    with open(os.path.join(args.out, "airos_release"), "w") as f:
        f.write(package_info("airos_release", version, args.arch,
            f"air/OS release of {when} for {args.target}",
            "Names the air/OS release this system runs, for System Updater "
            "and the boot loader's list of versions.",
            "airos_release"))
    with open(os.path.join(args.out, "airos_payload"), "w") as f:
        f.write(package_info("airos_payload", version, args.arch,
            f"air/OS system files outside packages, {when}",
            "The GPU stacks, drivers and firmware of the air/OS release that "
            "live in system/non-packaged, which links to them here, so that "
            "they change with the release and an older version brings its "
            "own back; on arm64 also GLTeapot and GLInfo, in system/demos "
            "and system/apps.",
            "airos_payload"))

    # one rule per file of each tree, so that jam knows every file
    lines = ["# written by airos-ci images/release-inputs.py"]
    for spec in args.tree:
        tokens, _, directory = spec.partition("=")
        tokens = tokens.split()
        if not directory or not os.path.isdir(directory):
            continue
        directory = os.path.abspath(directory)
        for root, dirs, files in os.walk(directory):
            dirs.sort()
            relative = os.path.relpath(root, directory)
            parts = tokens + ([] if relative == "." else relative.split(os.sep))
            dirTokens = " ".join(jam_quote(t) for t in parts)
            for name in sorted(files + [d for d in dirs
                    if os.path.islink(os.path.join(root, d))]):
                path = os.path.join(root, name)
                if os.path.islink(path):
                    lines.append(f"AirosCISymlink {dirTokens} : "
                        f"{jam_quote(os.readlink(path))} : {jam_quote(name)} ;")
                elif os.path.isfile(path):
                    lines.append(f"AirosCIFile {dirTokens} : {jam_quote(path)} "
                        f": {jam_quote(name)} ;")
            # os.walk does not descend into symlinked directories
            dirs[:] = [d for d in dirs if not os.path.islink(os.path.join(root, d))]
    with open(os.path.join(args.out, "files.jam"), "w") as f:
        f.write("\n".join(lines) + "\n")
    print(f"release {args.id}: version {version}, "
        f"{len(lines) - 1} files of CI's trees")


if __name__ == "__main__":
    main()
