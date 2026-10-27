#!/usr/bin/env python3
"""CI status of every airos-works repository, for the build server's /ci/ page.

Writes $AIROS_ARTIFACTS/ci/status.json (served by nginx with
dashboard/ci.html as /ci/index.html; dashboard/install-repo-status.sh sets it
up). Runs from cron once a minute as an account whose `gh` is logged in to
GitHub, not as the runner user: the token must stay out of reach of the jobs
the runners execute.

Each repository's CI is its air/OS workflows: the files named airos*.yml, and
the extra ones in PRIMARY below. A repository is
  building  while the newest run of one of them is queued or running,
  failed    when the newest finished run of one of them failed,
  passed    otherwise.
Cancelled and skipped runs do not count as results (a newer push cancels the
run before it). Other workflows (upstream CI in the forks) are listed with
their newest result but leave the repository's status alone.

Requests carry the ETags of the last answers: unchanged answers (304) cost
GitHub no rate limit. The list of repositories and their workflows is renewed
every DISCOVER_SECONDS.
"""
import datetime
import fcntl
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

ORG = os.environ.get("GITHUB_OWNER", "airos-works")
OUT = os.environ.get("CI_STATUS_DIR",
                     os.path.join(os.environ.get("AIROS_ARTIFACTS", "/data2/airos/artifacts"), "ci"))
CACHE = os.environ.get("CI_STATUS_CACHE", os.path.expanduser("~/.cache/airos-ci-status"))
DISCOVER_SECONDS = 3600
# Workflows that are a repository's air/OS CI besides .github/workflows/airos*.yml.
PRIMARY = {("airos-ci", ".github/workflows/sdk-deps.yml"),
           ("airos-website", ".github/workflows/pages.yml")}
# Runs that are builds of a branch (not pull requests from elsewhere).
EVENTS = {"push", "schedule", "workflow_dispatch", "repository_dispatch", "workflow_run"}
ACTIVE = {"queued", "in_progress", "waiting", "pending", "requested"}
FAILED = {"failure", "timed_out", "startup_failure", "action_required"}
IGNORED = {"cancelled", "skipped", "neutral", "stale", None}
OTHER_DAYS = 30  # other workflows are listed while their newest run is this recent

token = os.environ.get("GH_TOKEN") or subprocess.check_output(["gh", "auth", "token"], text=True).strip()
os.makedirs(CACHE, exist_ok=True)
etag_path = os.path.join(CACHE, "responses.json")
try:
    with open(etag_path) as f:
        responses = json.load(f)
except (OSError, ValueError):
    responses = {}
used = set()


def api(path):
    """GET a GitHub API path; an unchanged answer comes from the cache."""
    used.add(path)
    headers = {"Authorization": "Bearer " + token, "Accept": "application/vnd.github+json",
               "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "airos-ci-status"}
    cached = responses.get(path)
    if cached:
        headers["If-None-Match"] = cached["etag"]
    request = urllib.request.Request("https://api.github.com/" + path, headers=headers)
    for attempt in range(3):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = json.load(response)
                if response.headers.get("ETag"):
                    responses[path] = {"etag": response.headers["ETag"], "body": body}
                return body
        except urllib.error.HTTPError as error:
            if error.code == 304 and cached:
                return cached["body"]
            if error.code not in (500, 502, 503, 504) or attempt == 2:
                raise
        except urllib.error.URLError:
            if attempt == 2:
                raise
        time.sleep(2 ** attempt)


def iso(text):
    return datetime.datetime.fromisoformat(text.replace("Z", "+00:00")) if text else None


def discover():
    """The organization's repositories and their active workflows."""
    path = os.path.join(CACHE, "repos.json")
    try:
        with open(path) as f:
            known = json.load(f)
        if time.time() - known["time"] < DISCOVER_SECONDS:
            return known["repos"]
    except (OSError, ValueError, KeyError):
        pass
    repos = []
    page = 1
    while True:
        batch = api(f"orgs/{ORG}/repos?type=all&per_page=100&page={page}")
        repos += batch
        if len(batch) < 100:
            break
        page += 1

    def workflows(repo):
        if repo["archived"] or repo.get("disabled"):
            return None
        try:
            result = api(f"repos/{ORG}/{repo['name']}/actions/workflows?per_page=100")
        except urllib.error.HTTPError:
            return None
        flows = [{"id": w["id"], "name": w["name"], "path": w["path"],
                  "primary": os.path.basename(w["path"]).startswith("airos")
                             or (repo["name"], w["path"]) in PRIMARY}
                 for w in result["workflows"] if w["state"] == "active"]
        if not flows:
            return None
        return {"name": repo["name"], "url": repo["html_url"], "private": repo["private"],
                "default_branch": repo["default_branch"], "workflows": flows}

    with ThreadPoolExecutor(8) as pool:
        found = [r for r in pool.map(workflows, repos) if r]
    with open(path, "w") as f:
        json.dump({"time": time.time(), "repos": found}, f)
    return found


def run_summary(run):
    return {"id": run["id"], "number": run["run_number"], "url": run["html_url"],
            "status": run["status"], "conclusion": run["conclusion"], "event": run["event"],
            "branch": run["head_branch"], "sha": run["head_sha"],
            "title": ((run.get("display_title") or "").splitlines() or [""])[0][:120],
            "started": run.get("run_started_at") or run["created_at"], "updated": run["updated_at"]}


def jobs(run, which):
    """Names of a run's jobs that are running (which="active") or failed."""
    try:
        result = api(f"repos/{ORG}/{run['repo']}/actions/runs/{run['id']}/jobs?per_page=100")
    except urllib.error.HTTPError:
        return {}
    every = result["jobs"]
    done = sum(1 for j in every if j["status"] == "completed")
    if which == "active":
        names = [j["name"] for j in every if j["status"] in ACTIVE]
    else:
        names = [j["name"] for j in every if j["conclusion"] in FAILED]
    return {"jobs_total": len(every), "jobs_done": done, "jobs": names}


def workflow_state(repo, flow):
    runs = api(f"repos/{ORG}/{repo['name']}/actions/workflows/{flow['id']}/runs"
               f"?per_page=20&exclude_pull_requests=true")["workflow_runs"]
    runs = [r for r in runs if r["event"] in EVENTS]
    if not runs:
        return None
    # The branch CI builds is the branch of the newest run (Code - OSS and
    # GitHub Desktop build "haiku", not their default branches).
    branch = runs[0]["head_branch"]
    runs = [r for r in runs if r["head_branch"] == branch]
    active = next((r for r in runs if r["status"] in ACTIVE), None)
    finished = next((r for r in runs if r["status"] == "completed" and r["conclusion"] not in IGNORED), None)
    state = {"name": flow["name"], "path": flow["path"], "primary": flow["primary"], "branch": branch,
             "url": f"{repo['url']}/actions/workflows/{os.path.basename(flow['path'])}",
             "active": None, "last": None}
    if active:
        state["active"] = {**run_summary(active), **jobs({**active, "repo": repo["name"]}, "active")}
    if finished:
        state["last"] = run_summary(finished)
        if finished["conclusion"] in FAILED:
            state["last"].update(jobs({**finished, "repo": repo["name"]}, "failed"))
    state["result"] = ("building" if active else
                       "failed" if finished and finished["conclusion"] in FAILED else
                       "passed" if finished else "none")
    return state


def repo_state(repo):
    flows = []
    for flow in repo["workflows"]:
        try:
            state = workflow_state(repo, flow)
        except urllib.error.HTTPError as error:
            state = {"name": flow["name"], "path": flow["path"], "primary": flow["primary"],
                     "result": "unknown", "error": f"HTTP {error.code}"}
        if state:
            flows.append(state)
    primary = [f for f in flows if f["primary"]]
    if not primary:
        return None
    now = datetime.datetime.now(datetime.timezone.utc)
    others = [f for f in flows if not f["primary"] and (f.get("active") or (
        f.get("last") and now - iso(f["last"]["updated"]) < datetime.timedelta(days=OTHER_DAYS)))]
    results = {f["result"] for f in primary}
    status = ("building" if "building" in results else
              "failed" if "failed" in results else
              "passed" if "passed" in results else "unknown")
    times = [iso(r["updated"]) for f in primary for r in (f.get("active"), f.get("last")) if r]
    return {"name": repo["name"], "url": repo["url"], "private": repo["private"], "status": status,
            "updated": max(times).isoformat() if times else None,
            "workflows": primary, "other_workflows": others}


def main():
    os.makedirs(OUT, exist_ok=True)
    lock = open(os.path.join(CACHE, "lock"), "w")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        return  # the previous minute's run is still going
    repos = discover()
    with ThreadPoolExecutor(8) as pool:
        states = [s for s in pool.map(repo_state, repos) if s]
    order = {"building": 0, "failed": 1, "passed": 2, "unknown": 3}
    states.sort(key=lambda s: (order[s["status"]], s["name"].lower()))
    rate = api_rate()
    document = {"org": ORG, "generated": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds"),
                "counts": {k: sum(1 for s in states if s["status"] == k) for k in order},
                "repos": states, "rate_limit": rate}
    fd, tmp = tempfile.mkstemp(dir=OUT, prefix=".status-", suffix=".json")
    with os.fdopen(fd, "w") as f:
        json.dump(document, f, indent=1)
    os.chmod(tmp, 0o664)
    os.replace(tmp, os.path.join(OUT, "status.json"))
    # Keep only the answers still asked for (finished runs' job lists drop out).
    kept = {p: responses[p] for p in used if p in responses}
    with open(etag_path + ".tmp", "w") as f:
        json.dump(kept, f)
    os.replace(etag_path + ".tmp", etag_path)


def api_rate():
    request = urllib.request.Request("https://api.github.com/rate_limit", headers={
        "Authorization": "Bearer " + token, "User-Agent": "airos-ci-status"})
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            core = json.load(response)["resources"]["core"]
            return {"remaining": core["remaining"], "limit": core["limit"]}
    except (urllib.error.URLError, KeyError, ValueError):
        return None


if __name__ == "__main__":
    try:
        main()
    except Exception as error:  # cron mails nobody: leave the reason next to the page
        os.makedirs(OUT, exist_ok=True)
        with open(os.path.join(OUT, "error.txt"), "w") as f:
            f.write(f"{datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds')} {error!r}\n")
        raise
    else:
        try:
            os.remove(os.path.join(OUT, "error.txt"))
        except FileNotFoundError:
            pass
