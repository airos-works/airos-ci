#!/usr/bin/env python3
"""Packages inside a built image (its BFS partition, through bfs_shell).

    image-package.py replace IMAGE TOOLS PACKAGE [--kernel-debug-level N]
        Puts PACKAGE into the image's system/packages in place of the package
        of the same name, version and architecture, under the same file name,
        so the boot loader and packagefs take it as the image's own.
        smoke-test.sh boots its copy of an image this way with the haiku
        package build-image.sh built with the kernel's debug checks.
        --kernel-debug-level N first checks that the package's kernel was
        built at that level: it defines kernel_debug_level_N (Haiku's
        headers/private/kernel/debug.h).

TOOLS is the build's objects/linux/<arch>/release/tools (package, bfs_shell).
The image is a copy (the smoke test's), never a published one.
"""

import argparse
import importlib.util
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("release_feed",
    os.path.join(HERE, "release-feed.py"))
release_feed = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(release_feed)

PACKAGES = "myfs/system/packages"


def kernel_debug_level(tools, package):
    """The debug levels the package's kernel defines (normally one)."""
    with tempfile.TemporaryDirectory(prefix="image-package-") as directory:
        subprocess.run([os.path.join(tools, "package", "package"), "extract",
            "-C", directory, package], check=True, stdout=subprocess.DEVNULL)
        kernels = [name for name in os.listdir(directory)
            if name.startswith("kernel_")
            and os.path.isfile(os.path.join(directory, name))]
        if not kernels:
            sys.exit(f"{package} has no kernel")
        data = open(os.path.join(directory, kernels[0]), "rb").read()
    return [level for level in range(4)
        if b"kernel_debug_level_%d\0" % level in data]


def command_replace(args):
    info = release_feed.package_info(args.tools, args.package)
    if not info["name"] or not info["version"]:
        sys.exit(f"cannot read the name and version of {args.package}")
    name = f"{info['name']}-{info['version']}-{info['architecture']}.hpkg"
    if args.kernel_debug_level is not None:
        levels = kernel_debug_level(args.tools, args.package)
        if levels != [args.kernel_debug_level]:
            sys.exit(f"{args.package}: its kernel is built for debug level "
                f"{levels or 'unknown'}, not {args.kernel_debug_level}")
    listing = release_feed.bfs_shell(args.tools, args.image,
        [f"ls {PACKAGES}"])
    if name not in listing.split():
        sys.exit(f"{args.image} has no {name} to replace (the package must be "
            f"of the image's own build):\n{listing[-3000:]}")
    size = os.path.getsize(args.package)
    listing = release_feed.bfs_shell(args.tools, args.image, [
        f"rm {PACKAGES}/{name}",
        f"cp :{os.path.abspath(args.package)} {PACKAGES}/{name}",
        f"ls {PACKAGES}",
        "sync"])
    line = next((line for line in listing.splitlines()
        if line.split() and line.split()[-1] == name), "")
    if str(size) not in line.split():
        sys.exit(f"bfs_shell did not put {args.package} ({size} bytes) into "
            f"{args.image}:\n{listing[-3000:]}")
    print(f"{name} in {os.path.basename(args.image)} is now {args.package}")


def main():
    parser = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    replace = commands.add_parser("replace")
    replace.add_argument("image")
    replace.add_argument("tools")
    replace.add_argument("package")
    replace.add_argument("--kernel-debug-level", type=int)
    args = parser.parse_args()
    {"replace": command_replace}[args.command](args)


if __name__ == "__main__":
    main()
