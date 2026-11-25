#!/usr/bin/env python3
"""pgo-coverage.py BUILD_DIR PROFILE_DIR: how much of the engine a PGO profile covers.

GCC names each counter file after its object's path relative to the build
directory ('/' -> '#', '.o' dropped), so an object compiled without a counter
file was not run during training (or did not exist then) and is optimized as
without a profile. This prints, for WebCore and JavaScriptCore and for their
hot source groups (DOM, style, layout, rendering, bindings, the JIT tiers,
runtime, heap), how many objects have counters, and lists uncovered objects of
those groups so a stale or partial profile shows in the build log (Summit #280).
"""
import collections
import os
import re
import sys

HOT = {
    'WebCore': ['dom', 'css', 'style', 'layout', 'rendering', 'html', 'bindings', 'page', 'svg', 'platform'],
    'JavaScriptCore': ['runtime', 'bytecode', 'bytecompiler', 'interpreter', 'llint', 'jit', 'dfg', 'ftl', 'b3', 'heap', 'parser', 'yarr'],
}


def objects(build_dir):
    pattern = re.compile(r'^build (Source/(WebCore|JavaScriptCore)/CMakeFiles/[^ :]+\.o)[ :]')
    with open(os.path.join(build_dir, 'build.ninja'), errors='replace') as ninja:
        for line in ninja:
            match = pattern.match(line)
            if match:
                yield match.group(2), match.group(1)


def group(path):
    name = os.path.basename(path)
    unified = re.match(r'UnifiedSource-([A-Za-z0-9_]+?)-\d+\.cpp\.o$', name)
    if unified:
        return unified.group(1)
    parts = path.split('/')
    return parts[4] if len(parts) > 5 else 'other'


def main():
    build_dir, profile_dir = sys.argv[1:3]
    counters = set(os.listdir(profile_dir))
    totals = collections.Counter()
    covered = collections.Counter()
    missing = collections.defaultdict(list)
    for library, path in objects(build_dir):
        key = (library, group(path))
        totals[library, None] += 1
        totals[key] += 1
        if path[:-2].replace('/', '#') + '.gcda' in counters:
            covered[library, None] += 1
            covered[key] += 1
        elif key[1] in HOT[library]:
            missing[key].append(os.path.basename(path))
    for library, groups in HOT.items():
        total = totals[library, None]
        if not total:
            continue
        line = [f'PGO coverage {library}: {covered[library, None]}/{total} objects']
        for name in groups:
            if totals[library, name]:
                line.append(f'{name} {covered[library, name]}/{totals[library, name]}')
        print(', '.join(line))
        for name in groups:
            if missing[library, name]:
                shown = ' '.join(sorted(missing[library, name])[:6])
                more = len(missing[library, name]) - 6
                print(f'  no counters for {library} {name}: {shown}' + (f' (+{more})' if more > 0 else ''))


if __name__ == '__main__':
    main()
