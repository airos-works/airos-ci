#!/usr/bin/env python3
"""publish-feed-github.py: System Updater's feed of a target on GitHub Releases
(airos-works/haiku docs/airos/SYSTEM-UPDATER.md).

    publish-feed-github.py TARGET [--feed DIR] [--repo OWNER/NAME] [--keep N]
        [--dry-run]

Mirrors the newest KEEP releases of the build server's feed (default
$AIROS_ARTIFACTS/updates/TARGET, written by release-feed.py publish) to
GitHub, so that air/OS machines update from GitHub's servers:

    update-TARGET-<release id>   one prerelease per release: its update.json
                                 and the packages (and Pi boot files) that no
                                 earlier one of them has
    updates-TARGET               the feed's address, holding index.json:
        https://github.com/OWNER/NAME/releases/download/updates-TARGET/

Every address in the mirrored index.json and update.json files is absolute;
each package is uploaded once, to the release that brought it, and later
releases point at that asset. A package CI built again with only other file
times ("equivalent" in the feed) is not uploaded again: the release lists the
copy already on GitHub. index.json changes last, after everything it names is
there, so a machine never sees a release whose files are missing. Releases
the index no longer names and no kept release uses are deleted.

Running it again does only what is missing; GitHub's SHA-256 digests of the
assets tell what is there.
"""
import argparse
import hashlib
import json
import os
import subprocess
import sys
import tempfile
import urllib.parse
import urllib.request

KEEP = int(os.environ.get("AIROS_GITHUB_UPDATE_KEEP", "6"))


def gh(*args, data=None):
    return subprocess.run(["gh", *args], input=data, check=True, text=True,
        stdout=subprocess.PIPE).stdout


def gh_json(*args):
    return json.loads(gh(*args))


def sha256_bytes(data):
    return hashlib.sha256(data).hexdigest()


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


class Repository:
    def __init__(self, name, dry_run):
        self.name = name
        self.dry_run = dry_run

    def download_url(self, tag, asset_name):
        return (f"https://github.com/{self.name}/releases/download/"
            f"{urllib.parse.quote(tag)}/{urllib.parse.quote(asset_name)}")

    def releases(self, prefix):
        """The releases whose tag starts with prefix (drafts included)."""
        result = {}
        page = 1
        while True:
            releases = gh_json("api",
                f"repos/{self.name}/releases?per_page=100&page={page}")
            for release in releases:
                if release["tag_name"].startswith(prefix):
                    result[release["tag_name"]] = release
            if len(releases) < 100:
                return result
            page += 1

    def release(self, release_id):
        return gh_json("api", f"repos/{self.name}/releases/{release_id}")

    def create(self, tag, title, notes, draft):
        if self.dry_run:
            print(f"would create {tag}")
            return {"id": 0, "tag_name": tag, "draft": draft, "assets": []}
        with tempfile.NamedTemporaryFile("w", suffix=".md") as note:
            note.write(notes)
            note.flush()
            args = ["release", "create", tag, "--repo", self.name,
                "--prerelease", "--title", title, "--notes-file", note.name,
                "--target", "master"]
            if draft:
                args.append("--draft")
            gh(*args)
        api = gh_json("release", "view", tag, "--repo", self.name,
            "--json", "apiUrl")["apiUrl"]
        return gh_json("api", api)

    def upload(self, release, paths):
        """Uploads paths (local files) to release; returns its new assets
        by their SHA-256, checked against GitHub's digests."""
        if not paths:
            return {}
        if self.dry_run:
            print(f"would upload {len(paths)} files to {release['tag_name']}")
            return {}
        # gh resolves a draft's tag itself; the REST tag endpoint does not
        for start in range(0, len(paths), 20):
            gh("release", "upload", release["tag_name"], "--repo", self.name,
                "--clobber", *paths[start:start + 20])
        remote = self.release(release["id"])
        by_digest = {}
        for asset in remote["assets"]:
            if asset.get("state") == "uploaded" and asset.get("digest"):
                by_digest[asset["digest"].removeprefix("sha256:")] = asset
        for path in paths:
            if sha256_file(path) not in by_digest:
                raise RuntimeError(f"{os.path.basename(path)} did not reach "
                    f"{release['tag_name']} intact")
        return by_digest

    def publish(self, release):
        if not self.dry_run:
            gh("api", "-X", "PATCH",
                f"repos/{self.name}/releases/{release['id']}", "-F",
                "draft=false")

    def replace_asset(self, release, name, path):
        """Puts path in release as name: uploaded beside the old one first,
        so that name is missing only between a delete and a rename."""
        if self.dry_run:
            print(f"would replace {release['tag_name']}/{name}")
            return
        staged = f"next-{name}"
        old = [a for a in release["assets"] if a["name"] in (name, staged)]
        for asset in old:
            if asset["name"] == staged:
                gh("api", "-X", "DELETE",
                    f"repos/{self.name}/releases/assets/{asset['id']}")
        with tempfile.TemporaryDirectory() as work:
            upload = os.path.join(work, staged)
            with open(path, "rb") as source, open(upload, "wb") as target:
                target.write(source.read())
            gh("release", "upload", release["tag_name"], "--repo", self.name,
                upload)
        remote = self.release(release["id"])
        new = next(a for a in remote["assets"] if a["name"] == staged)
        if new.get("digest") != "sha256:" + sha256_file(path):
            raise RuntimeError(f"{name} did not reach {release['tag_name']} "
                "intact")
        for asset in old:
            if asset["name"] == name:
                gh("api", "-X", "DELETE",
                    f"repos/{self.name}/releases/assets/{asset['id']}")
        gh("api", "-X", "PATCH",
            f"repos/{self.name}/releases/assets/{new['id']}", "-f",
            f"name={name}")

    def delete(self, tag):
        if self.dry_run:
            print(f"would delete {tag}")
            return
        gh("release", "delete", tag, "--repo", self.name, "--cleanup-tag",
            "--yes")


def known_assets(repository, releases):
    """SHA-256 -> (url, size) of every package and boot file on GitHub."""
    known = {}
    for release in releases.values():
        if release.get("draft"):
            continue
        for asset in release["assets"]:
            digest = (asset.get("digest") or "").removeprefix("sha256:")
            if digest and asset.get("state") == "uploaded" \
                    and asset["name"] != "update.json":
                known.setdefault(digest, (repository.download_url(
                    release["tag_name"], asset["name"]), asset["size"]))
    return known


def mirror_release(repository, feed, target, build, releases, known):
    """Makes the GitHub release of one feed release, if it is missing;
    returns its update.json as published there."""
    tag = f"update-{target}-{build['id']}"
    local = json.load(open(os.path.join(feed, build["manifest"])))
    existing = releases.get(tag)
    if existing and not existing.get("draft"):
        if any(a["name"] == "update.json" for a in existing["assets"]):
            # exactly what machines download, for the index's SHA-256
            with urllib.request.urlopen(repository.download_url(tag,
                    "update.json"), timeout=60) as answer:
                return answer.read().decode()

    release = existing or repository.create(tag,
        f"air/OS {target} update {build['id']}",
        f"System Updater's packages for the air/OS {target} release "
        f"`{build['id']}` (built {build.get('built', '')}).\n\n"
        "Machines find it through the `updates-" + target + "` release's "
        "`index.json`; nothing here is meant to be downloaded by hand.\n",
        draft=True)

    # what is not on GitHub yet goes into this release
    uploads = []
    planned = {}
    for kind, directory in (("packages", "packages"), ("boot_files", "boot")):
        for entry in local.get(kind, []):
            digest = entry["sha256"]
            if digest in known or digest in planned:
                continue
            # a package rebuilt with only other file times: its earlier copy
            if kind == "packages" and any(d in known
                    for d in entry.get("equivalent", [])):
                continue
            name = entry["file"] if kind == "packages" else entry["name"]
            path = os.path.join(feed, directory, digest, name)
            if not os.path.isfile(path):
                raise RuntimeError(f"{path} is missing from the feed")
            uploads.append(path)
            planned[digest] = name
    print(f"{tag}: {len(uploads)} new files, "
        f"{sum(os.path.getsize(p) for p in uploads) >> 20} MiB")
    for digest, asset in repository.upload(release, uploads).items():
        known[digest] = (repository.download_url(tag, asset["name"]),
            asset["size"])
    if repository.dry_run:
        for digest, name in planned.items():
            known[digest] = (repository.download_url(tag, name), 0)

    # the release's update.json with GitHub's addresses
    for entry in local.get("packages", []):
        digest = entry["sha256"]
        if digest not in known:
            # the copy on GitHub of an equivalent build of the package
            copy = next(d for d in reversed(entry.get("equivalent", []))
                if d in known)
            entry["equivalent"] = [d for d in entry["equivalent"]
                if d != copy] + [digest]
            entry["sha256"] = copy
            entry["size"] = known[copy][1]
            digest = copy
        entry["url"] = known[digest][0]
    for entry in local.get("boot_files", []):
        entry["url"] = known[entry["sha256"]][0]
    text = json.dumps(local, indent=1, ensure_ascii=False) + "\n"
    with tempfile.TemporaryDirectory() as work:
        path = os.path.join(work, "update.json")
        with open(path, "w") as f:
            f.write(text)
        repository.upload(release, [path])
    repository.publish(release)
    return text


def main():
    parser = argparse.ArgumentParser(description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("target")
    parser.add_argument("--feed")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "airos-works/haiku"))
    parser.add_argument("--keep", type=int, default=KEEP)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    feed = os.path.abspath(args.feed or os.path.join(
        os.environ.get("AIROS_ARTIFACTS", "/data2/airos/artifacts"), "updates",
        args.target))
    index = json.load(open(os.path.join(feed, "index.json")))
    if index.get("target") != args.target:
        sys.exit(f"{feed} is the feed of {index.get('target')}")
    builds = sorted(index["builds"], key=lambda b: b["id"],
        reverse=True)[:args.keep]

    repository = Repository(args.repo, args.dry_run)
    prefix = f"update-{args.target}-"
    releases = repository.releases(prefix)
    known = known_assets(repository, releases)

    # oldest first: each release's new packages go into the first one
    # that has them
    entries = []
    manifests = {}
    for build in reversed(builds):
        text = mirror_release(repository, feed, args.target, build, releases,
            known)
        manifests[build["id"]] = json.loads(text)
        entry = dict(build)
        entry["manifest"] = repository.download_url(prefix + build["id"],
            "update.json")
        entry["manifest_sha256"] = sha256_bytes(text.encode())
        entries.append(entry)
    entries.reverse()

    mirrored = dict(index)
    mirrored["builds"] = entries
    feed_tag = f"updates-{args.target}"
    feed_release = repository.releases(feed_tag).get(feed_tag)
    if feed_release is None:
        feed_release = repository.create(feed_tag,
            f"air/OS {args.target} updates",
            f"The System Updater feed of air/OS {args.target}: `index.json` "
            "lists the newest releases, each in an `update-"
            f"{args.target}-<id>` release. System Updater reads "
            f"https://github.com/{args.repo}/releases/download/{feed_tag}/"
            "index.json.\n", draft=False)
    with tempfile.TemporaryDirectory() as work:
        path = os.path.join(work, "index.json")
        with open(path, "w") as f:
            json.dump(mirrored, f, indent=1, ensure_ascii=False)
            f.write("\n")
        repository.replace_asset(feed_release, "index.json", path)
    print(f"https://github.com/{args.repo}/releases/download/{feed_tag}/"
        f"index.json: {len(entries)} releases, newest {entries[0]['id']}")

    # releases the index dropped, unless a kept one uses their files
    used = set()
    for manifest in manifests.values():
        for entry in manifest.get("packages", []) + manifest.get(
                "boot_files", []):
            used.add(entry["url"])
    kept = {prefix + b["id"] for b in builds}
    for tag, release in releases.items():
        if tag in kept:
            continue
        if release.get("draft") or not any(repository.download_url(tag,
                a["name"]) in used for a in release["assets"]):
            repository.delete(tag)


if __name__ == "__main__":
    main()
