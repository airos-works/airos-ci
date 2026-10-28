#!/usr/bin/env python3
# prune-attributes.py <build>/attributes <root>...
#
# Removes the entries of a Haiku build directory's attribute store that no
# file refers to any more. With HAIKU_HOST_USE_XATTR_REF the build's attribute
# emulation (libroot_build) keeps a file's attributes in attributes/<id>,
# where <id> is the file's user.haiku.id, and nothing removes the entry when
# the file is deleted or rebuilt. The roots are searched for the IDs files
# still carry (the build directories' own stores are skipped). Entries of
# symlinks (symlink-<inode>, build-image.sh) and entries changed since the
# search started stay. Run it under the build directory's lock.
import os
import shutil
import sys
import time

store, roots = sys.argv[1], sys.argv[2:]
start = time.time()

live = set()
files = 0
stack = list(roots)
while stack:
	directory = stack.pop()
	try:
		entries = list(os.scandir(directory))
	except OSError:
		continue
	build_dir = os.path.exists(os.path.join(directory, "build", "BuildConfig"))
	for entry in entries:
		try:
			if entry.is_dir(follow_symlinks=False):
				if build_dir and entry.name.startswith("attributes"):
					continue
				stack.append(entry.path)
			files += 1
			live.add(os.getxattr(entry.path, "user.haiku.id",
				follow_symlinks=False).decode(errors="replace"))
		except OSError:
			pass

# a search that found next to nothing went wrong; better to keep everything
if len(live) < 10000:
	sys.exit(f"prune-attributes: only {len(live)} IDs in {files} files, nothing removed")

kept = removed = 0
for entry in os.scandir(store):
	try:
		if (entry.name.startswith("symlink-") or entry.name in live
				or entry.stat(follow_symlinks=False).st_mtime >= start):
			kept += 1
			continue
		shutil.rmtree(entry.path) if entry.is_dir(follow_symlinks=False) \
			else os.unlink(entry.path)
		removed += 1
	except OSError:
		pass
print(f"attribute store {store}: {files} files searched, {kept} entries kept, "
	f"{removed} removed")
