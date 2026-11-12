#!/usr/bin/env python3
"""store-symbols.py: keep the symbol tables of a stripped package's binaries.

Summit's packages ship stripped (the engine's libraries --strip-unneeded), so
the frames of its crash reports name only an image and an offset. Before
stripping, apps/build-app-packages.sh saves each binary's symbols
(`objcopy --only-keep-debug`) under SYMBOLS/<path in the package>; this files
them in the store (AIROS_SYMBOLS, served at http://airos-build/symbols/):

  build-id/ab/cdef….debug.xz   the symbol table, by the binary's GNU build ID
                               (the engine, Summit), the ID Summit's crash
                               reports print
  build-id/ab/cdef….lines.xz   its line tables (DWARF), when it was built with
                               them (-g1: the engine, Summit)
  sha256/<sha256>.debug.xz     binaries without a build ID (the engine's
                               third-party libraries), by the SHA-256 of the
                               shipped file
  builds/<package>-<version>-<arch>.json
                               the builds of that package version: target
                               SDK, commit, time and every binary (path in
                               the package, build ID, SHA-256, objects)

An object is written once: a rebuild that comes out the same (the nightly
pool refresh of an unchanged commit) adds only its entry to the build list.
Symbol tables are kept; line tables, about 180 MB per engine build, are
removed --prune-lines-days after the last build that has them (checked once a
day). Summit's tools/symbolize-crash-report.py reads the store.

  store-symbols.py --stage STAGE --symbols SYMBOLS --store STORE
      --package NAME --version VERSION --arch ARCH --sdk SDK_NAME
      [--commit SHA] [--objcopy OBJCOPY] [--prune-lines-days DAYS]
"""
import argparse
import datetime
import fcntl
import hashlib
import json
import os
import pathlib
import shutil
import struct
import subprocess
import sys
import tempfile

PT_NOTE = 4
NT_GNU_BUILD_ID = 3


def elf_sections(data):
    """{name: (addr, size)} of a 64-bit little-endian ELF file."""
    if data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
        return None
    shoff, = struct.unpack_from('<Q', data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', data, 0x3a)
    if not shoff or shstrndx >= shnum:
        return {}
    headers = [struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * shentsize) for i in range(shnum)]
    names_offset = headers[shstrndx][4]
    result = {}
    for name, _type, _flags, addr, _offset, size, *_ in headers:
        end = data.index(b'\0', names_offset + name)
        result[data[names_offset + name:end].decode()] = (addr, size)
    return result


def build_id(data):
    """The GNU build ID of an ELF file (hex), from its note segments."""
    phoff, = struct.unpack_from('<Q', data, 0x20)
    phentsize, phnum = struct.unpack_from('<HH', data, 0x36)
    for i in range(phnum):
        p_type, _flags, offset, _vaddr, _paddr, filesz, _memsz, _align = struct.unpack_from(
            '<IIQQQQQQ', data, phoff + i * phentsize)
        if p_type != PT_NOTE:
            continue
        at, end = offset, offset + filesz
        while at + 12 <= end:
            namesz, descsz, n_type = struct.unpack_from('<III', data, at)
            name = at + 12
            desc = name + ((namesz + 3) & ~3)
            if n_type == NT_GNU_BUILD_ID and data[name:name + namesz] == b'GNU\0':
                return data[desc:desc + descsz].hex()
            at = desc + ((descsz + 3) & ~3)
    return None


def has_lines(sections):
    """Built with line tables: more than the few stray kilobytes of debug
    information a release build picks up from an object or two (libWebKit
    without -g has 3 KB of .debug_line; with -g1, 96 MB)."""
    return sections.get('.debug_line', (0, 0))[1] >= 65536


def prune_lines(store, days):
    """Drops line tables no build of the last DAYS days has, once a day."""
    stamp = store / 'builds' / '.pruned'
    now = datetime.datetime.now(datetime.timezone.utc)
    if stamp.exists() and now.timestamp() - stamp.stat().st_mtime < 86400:
        return
    cutoff = (now - datetime.timedelta(days=days)).strftime('%Y-%m-%dT%H:%M:%SZ')
    newest, documents = {}, {}
    for path in (store / 'builds').glob('*.json'):
        document = json.loads(path.read_text())
        documents[path] = document
        for build in document['builds']:
            for entry in build['files']:
                if entry.get('lines'):
                    newest[entry['lines']] = max(newest.get(entry['lines'], ''), build['built'])
    old = {lines for lines, built in newest.items() if built < cutoff}
    freed = 0
    for lines in old:
        target = store / lines
        if target.exists():
            freed += target.stat().st_size
            target.unlink()
    for path, document in documents.items():
        changed = False
        for build in document['builds']:
            for entry in build['files']:
                if entry.get('lines') in old:
                    entry['lines'] = None
                    changed = True
        if changed:
            temporary = path.with_name('.tmp-' + path.name)
            temporary.write_text(json.dumps(document, indent=1) + '\n')
            os.chmod(temporary, 0o664)
            os.replace(temporary, path)
    stamp.touch()
    if old:
        print(f'symbols: removed the line tables of {len(old)} binaries older than {days} days '
              f'({freed / 1073741824:.1f} GiB)')


def compress(source, target):
    """source -> target.xz, written under a temporary name and renamed."""
    target.parent.mkdir(parents=True, exist_ok=True)
    handle, temporary = tempfile.mkstemp(dir=target.parent, prefix='.tmp-')
    try:
        with os.fdopen(handle, 'wb') as out:
            if shutil.which('xz'):
                subprocess.run(['xz', '-T0', '-6', '-c', str(source)], stdout=out, check=True)
            else:
                import lzma
                out.write(lzma.compress(source.read_bytes(), preset=6))
        os.chmod(temporary, 0o664)
        os.replace(temporary, target)
    except BaseException:
        os.unlink(temporary)
        raise


def main():
    parser = argparse.ArgumentParser()
    for option in ('stage', 'symbols', 'store', 'package', 'version', 'arch', 'sdk'):
        parser.add_argument('--' + option, required=True)
    parser.add_argument('--commit', default='')
    parser.add_argument('--objcopy', default='objcopy')
    parser.add_argument('--prune-lines-days', type=int, default=0)
    args = parser.parse_args()
    stage, symbols, store = (pathlib.Path(p) for p in (args.stage, args.symbols, args.store))

    files, problems = [], []
    for debug in sorted(p for p in symbols.rglob('*') if p.is_file()):
        relative = debug.relative_to(symbols).as_posix()
        shipped = stage / relative
        if not shipped.is_file():
            problems.append(f'{relative}: not in the package')
            continue
        shipped_data = shipped.read_bytes()
        debug_data = debug.read_bytes()
        shipped_sections, debug_sections = elf_sections(shipped_data), elf_sections(debug_data)
        if shipped_sections is None or debug_sections is None:
            problems.append(f'{relative}: not a 64-bit ELF file')
            continue
        # The symbols must describe the shipped file's code: strip and
        # patchelf leave .text where it is.
        if shipped_sections.get('.text') != debug_sections.get('.text'):
            problems.append(f'{relative}: .text moved between the build and the package '
                            f'({debug_sections.get(".text")} -> {shipped_sections.get(".text")})')
            continue
        identity = build_id(shipped_data)
        digest = hashlib.sha256(shipped_data).hexdigest()
        base = f'build-id/{identity[:2]}/{identity[2:]}' if identity else f'sha256/{digest}'
        object_path, lines_path = base + '.debug.xz', None
        lines = has_lines(debug_sections)
        del shipped_data, debug_data
        if lines:
            lines_path = base + '.lines.xz'
            if not (store / lines_path).exists():
                compress(debug, store / lines_path)
        if not (store / object_path).exists():
            if lines:
                # The symbol table alone, which is kept when the line tables go.
                table = debug.with_name(debug.name + '.symtab')
                subprocess.run([args.objcopy, '--strip-debug', str(debug), str(table)], check=True)
                compress(table, store / object_path)
                table.unlink()
            else:
                compress(debug, store / object_path)
        files.append({'path': relative, 'buildId': identity, 'sha256': digest, 'symbols': object_path,
                      'lines': lines_path})

    builds = store / 'builds' / f'{args.package}-{args.version}-{args.arch}.json'
    builds.parent.mkdir(parents=True, exist_ok=True)
    entry = {
        'sdk': args.sdk,
        'commit': args.commit,
        'built': datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'),
        'files': files,
    }
    with open(store / 'builds' / '.lock', 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        document = {'package': args.package, 'version': args.version, 'arch': args.arch, 'builds': []}
        if builds.exists():
            document = json.loads(builds.read_text())
        # The same binaries again (a rebuild that came out identical) only
        # once per target.
        same = [b for b in document['builds'] if b['sdk'] == args.sdk
                and [f['sha256'] for f in b['files']] == [f['sha256'] for f in files]]
        if same:
            same[0]['built'] = entry['built']
        else:
            document['builds'].append(entry)
        temporary = builds.with_name('.tmp-' + builds.name)
        temporary.write_text(json.dumps(document, indent=1) + '\n')
        os.chmod(temporary, 0o664)
        os.replace(temporary, builds)

    size = sum((store / f['symbols']).stat().st_size for f in files)
    lines = sum((store / f['lines']).stat().st_size for f in files if f['lines'])
    print(f'symbols: {len(files)} binaries of {args.package} {args.version} ({args.sdk}), '
          f'{size / 1048576:.1f} MiB compressed'
          + (f', line tables of {sum(1 for f in files if f["lines"])} {lines / 1048576:.0f} MiB' if lines else '')
          + f', in {store}')
    if args.prune_lines_days:
        prune_lines(store, args.prune_lines_days)
    for problem in problems:
        print(f'::warning title=Symbols of {args.package}::{problem}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
