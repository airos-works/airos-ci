#!/usr/bin/env python3
"""Regression tests inside the images the smoke test boots.

The Haiku tree lists them in tools/airos/ci/guest-tests (jam targets);
build-image.sh builds them with the image and publishes the programs next to
it (guest-tests/). smoke-test.sh then:

  guest-tests.py inject IMAGE TOOLS TESTS
      copies the programs into the image's BFS partition (home/guest-tests)
      with a runner script, and a system launch job that starts the runner at
      boot. The runner writes everything to /dev/dprintf, so it lands on the
      serial log. TOOLS is the build's objects/linux/<arch>/release/tools.

  guest-tests.py check SERIAL TESTS
      reads the results from the serial log: every program must have run and
      exited with 0. Prints one line per test (and a failing test's output);
      exit status 0 when all passed.

The image is the smoke test's own decompressed copy, never the published one.
"""

import importlib.util
import os
import re
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("release_feed",
    os.path.join(HERE, "release-feed.py"))
release_feed = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(release_feed)

DIRECTORY = "home/guest-tests"
RUNNER = "run-guest-tests.sh"
JOB = "system/settings/launch/airos-guest-tests"
PREFIX = "GUEST TEST"
DONE = "GUEST TESTS DONE"

# Each test gets a minute; the runner kills it after that (coreutils timeout,
# when the image has it), so a test whose bug is back cannot stall the boot.
RUNNER_SCRIPT = f"""#!/bin/sh
# Written by airos-ci images/guest-tests.py for the smoke test: the Haiku
# tree's tools/airos/ci/guest-tests, run once at boot. Everything goes to the
# serial log through /dev/dprintf.
exec >/dev/dprintf 2>&1
echo "GUEST TESTS START"
for test in /boot/{DIRECTORY}/*; do
	name=${{test##*/}}
	[ "$name" = {RUNNER} ] && continue
	echo "{PREFIX} $name: start"
	{{
		if command -v timeout >/dev/null 2>&1; then
			timeout -s KILL 60 "$test" 2>&1
		else
			"$test" 2>&1
		fi
		echo "exit $?"
	}} | while IFS= read -r line; do
		echo "{PREFIX} $name: $line"
	done
done
echo "{DONE}"
"""

JOB_FILE = f"""# Written by airos-ci images/guest-tests.py: runs the smoke test's
# regression tests once at boot (/boot/{DIRECTORY}).
job x-vnd.airos-guest-tests {{
	launch /bin/sh /boot/{DIRECTORY}/{RUNNER}
}}
"""


def tests_in(directory):
    return sorted(name for name in os.listdir(directory)
        if os.path.isfile(os.path.join(directory, name)))


def command_inject(image, tools, directory):
    tests = tests_in(directory)
    if not tests:
        sys.exit(f"no guest tests in {directory}")
    with tempfile.TemporaryDirectory(prefix="guest-tests-") as scratch:
        runner = os.path.join(scratch, RUNNER)
        job = os.path.join(scratch, "job")
        with open(runner, "w") as f:
            f.write(RUNNER_SCRIPT)
        with open(job, "w") as f:
            f.write(JOB_FILE)
        commands = [f"mkdir -p myfs/{DIRECTORY}",
            f"mkdir -p myfs/{os.path.dirname(JOB)}"]
        for name in tests:
            commands += [f"cp :{os.path.join(directory, name)} myfs/{DIRECTORY}/{name}",
                f"chmod 755 myfs/{DIRECTORY}/{name}"]
        commands += [f"cp :{runner} myfs/{DIRECTORY}/{RUNNER}",
            f"chmod 755 myfs/{DIRECTORY}/{RUNNER}",
            f"cp :{job} myfs/{JOB}",
            f"ls myfs/{DIRECTORY}",
            "sync"]
        listing = release_feed.bfs_shell(tools, image, commands)
    missing = [name for name in tests + [RUNNER] if name not in listing]
    if missing:
        sys.exit(f"bfs_shell did not copy {', '.join(missing)} into {image}:\n"
            + listing[-2000:])
    print(f"guest tests in the image: {' '.join(tests)}")


def command_check(serial, directory):
    tests = tests_in(directory)
    with open(serial, "rb") as f:
        log = f.read().decode("utf-8", "replace")
    output = {name: [] for name in tests}
    status = {}
    pattern = re.compile(rf"{PREFIX} ([^:\s]+): (.*)")
    for line in log.splitlines():
        match = pattern.search(line)
        if not match or match.group(1) not in output:
            continue
        name, text = match.group(1), match.group(2).rstrip()
        exit_match = re.fullmatch(r"exit (\d+)", text)
        if exit_match:
            status[name] = int(exit_match.group(1))
        elif text != "start":
            output[name].append(text)
    finished = DONE in log
    passed = True
    for name in tests:
        if name not in status:
            state = "did not finish" if finished or output[name] else "did not run"
            print(f"guest test {name}: FAIL ({state})")
            passed = False
        elif status[name] != 0:
            print(f"guest test {name}: FAIL (exit {status[name]})")
            passed = False
        else:
            print(f"guest test {name}: PASS")
            continue
        for text in output[name][-20:]:
            print(f"    {text}")
    return 0 if passed else 1


def main():
    if len(sys.argv) == 5 and sys.argv[1] == "inject":
        command_inject(*sys.argv[2:])
        return 0
    if len(sys.argv) == 4 and sys.argv[1] == "check":
        return command_check(*sys.argv[2:])
    sys.exit(__doc__)


if __name__ == "__main__":
    sys.exit(main())
