#!/usr/bin/env python3
"""Prepare and validate a fork-only integration; never promote or force-push."""

import argparse
import base64
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time
from urllib.parse import urlencode

FORK = "DwennK/Plezy-SubtitleFix"
UPSTREAM = "edde746/plezy"
MAINTAINED = "feature/live-subtitle-sync"
INTEGRATION = "codex/upstream-sync"
MANIFEST = "docs/live-subtitle-sync-versions.json"
RECORD = "docs/livesync-upstream-integration.json"
WORKFLOWS = {
    "checks": "ci.yml", "dart": "livesync-dart.yml",
    "native": "livesync-mpv-build.yml", "macos": "livesync-macos.yml",
    "windows": "livesync-windows.yml",
}


def run(*args, cwd=None, input=None):
    return subprocess.run(args, cwd=cwd, input=input, text=True, check=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout.strip()


def git(root, *args):
    return run("git", *args, cwd=root)


def api(path):
    return json.loads(run("gh", "api", path))


def sha(value):
    if not re.fullmatch(r"[0-9a-f]{40}", value):
        raise ValueError("Expected an immutable Git SHA")
    return value


def ancestor(root, before, after):
    result = subprocess.run(["git", "merge-base", "--is-ancestor", before, after], cwd=root)
    if result.returncode not in (0, 1):
        raise RuntimeError("Unable to compare Git ancestry")
    return result.returncode == 0


class IntegrationConflict(RuntimeError):
    def __init__(self, files):
        self.files = files
        super().__init__("Integration conflicts: " + json.dumps(files))


def merge_candidate(root, maintained, upstream, existing=None):
    """Only call in a disposable clean checkout. Both input histories survive."""
    for revision in (maintained, upstream, *([existing] if existing else [])):
        sha(revision)
    if git(root, "status", "--porcelain"):
        raise ValueError("Integration requires a clean disposable checkout")
    start = existing if existing and not ancestor(root, existing, maintained) else maintained
    git(root, "checkout", "-B", INTEGRATION, start)
    for revision in (maintained, upstream):
        if ancestor(root, revision, "HEAD"):
            continue
        result = subprocess.run(["git", "merge", "--no-ff", "--no-edit", revision], cwd=root,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        if result.returncode:
            files = git(root, "diff", "--name-only", "--diff-filter=U", "-z").split("\0")
            files = sorted(f for f in files if f)
            # Abort only the merge this function just attempted, in this clone.
            git(root, "merge", "--abort")
            if files:
                raise IntegrationConflict(files)
            raise RuntimeError("Integration merge failed without resolvable conflict evidence")
    return sha(git(root, "rev-parse", "HEAD"))


def update_manifest(root, maintained, upstream, stable_release, components):
    path = root / MANIFEST
    manifest = json.loads(path.read_text())
    lock = json.loads((root / "mpv-build.lock.json").read_text())
    if lock["repo"] != "edde746/mpv-build":
        raise ValueError("Native repository changed; review required")
    setup = (root / ".github/actions/setup-flutter-git/action.yml").read_text()
    engine_script = (root / "windows/tool/install-patched-engine.ps1").read_text()
    version = re.search(r'\$version = "([0-9]+\.[0-9]+\.[0-9]+)"', setup)
    revision = re.search(r'\$expectedCommit = "([0-9a-f]{40})"', setup)
    engine = re.search(r"\$ExpectedEngine = '([0-9a-f]{40})'", engine_script)
    plezy = re.search(r"^version: ([^\s]+)$", (root / "pubspec.yaml").read_text(), re.M)
    if not all((version, revision, engine, plezy)):
        raise ValueError("Upstream toolchain pin format changed; review required")
    previous_version = manifest["flutter"]["version"]
    for name in ("livesync-dart.yml", "livesync-macos.yml"):
        workflow = root / ".github/workflows" / name
        text = workflow.read_text()
        old = f"flutter-version: '{previous_version}'"
        new = f"flutter-version: '{version[1]}'"
        if text.count(old) != 1 and text.count(new) != 1:
            raise ValueError("LiveSync SDK setup changed; review required")
        workflow.write_text(text.replace(old, new))
    now = datetime.now(timezone.utc).isoformat()
    manifest.update(recordedAt=now, status="integration-candidate-not-validated")
    manifest["upstream"].update(sha=upstream, commitDate=git(root, "show", "-s", "--format=%cI", upstream),
                                plezyVersion=plezy[1], stableRelease=stable_release)
    manifest["upstream"]["latestCheck"] = {
        "checkedAt": now, "latestSha": upstream, "integratedSha": upstream,
        "unintegratedCommits": 0, "scope": "Integration candidate only; maintained branch unchanged. Builds pending.",
    }
    manifest["native"].update(lock)
    manifest["native"]["components"] = components
    manifest["flutter"] = {"version": version[1], "revision": revision[1], "engine": engine[1]}
    manifest["integrationCandidate"] = {"maintainedBaseSha": maintained, "upstreamSha": upstream,
                                        "validated": False, "historicalChecksAreCandidateProof": False}
    path.write_text(json.dumps(manifest, indent=2) + "\n")
    (root / RECORD).write_text(json.dumps({
        "schema": 1, "maintainedBranch": MAINTAINED, "maintainedBaseSha": maintained,
        "upstreamSha": upstream, "stableRelease": stable_release, "createdAt": now,
        "promotion": "Review successful exact-SHA runs, then merge this branch without squashing or rebasing.",
    }, indent=2) + "\n")


def output(name, value):
    if "GITHUB_OUTPUT" in os.environ:
        with open(os.environ["GITHUB_OUTPUT"], "a") as stream:
            stream.write(f"{name}={value}\n")


def integration_prs():
    prs = json.loads(run("gh", "pr", "list", "--repo", FORK, "--base", MAINTAINED,
                         "--head", INTEGRATION, "--state", "open", "--json", "number,isDraft"))
    if len(prs) > 1:
        raise ValueError("Multiple integration PRs exist; refusing duplicate publication")
    return prs


def mark_pr_pending(candidate):
    prs = integration_prs()
    if not prs:
        return
    number = str(prs[0]["number"])
    if not prs[0]["isDraft"]:
        run("gh", "pr", "ready", number, "--undo", "--repo", FORK)
    with tempfile.TemporaryDirectory(prefix="livesync-pr-") as temporary:
        body = Path(temporary) / "body.md"
        body.write_text(f"Integration candidate `{candidate}` is awaiting validation.\n\n"
                        "Previous successful runs do not validate this new commit. "
                        "Do not promote until its Windows/macOS builds and checks succeed. "
                        "The maintained branch and previous test artifacts are unchanged.\n")
        run("gh", "pr", "edit", number, "--repo", FORK, "--body-file", str(body))


def prepare(root, report, validate_current=False):
    if os.environ.get("GITHUB_ACTIONS") != "true" or os.environ.get("GITHUB_REPOSITORY") != FORK:
        raise ValueError("Remote integration writes are restricted to this fork's Actions checkout")
    git(root, "fetch", "origin", f"refs/heads/{MAINTAINED}:refs/remotes/origin/{MAINTAINED}")
    git(root, "fetch", f"https://github.com/{UPSTREAM}.git", "refs/heads/main")
    maintained = sha(git(root, "rev-parse", f"origin/{MAINTAINED}"))
    upstream = sha(git(root, "rev-parse", "FETCH_HEAD"))
    releases = api(f"repos/{UPSTREAM}/releases/latest")
    report.update(maintainedBaseSha=maintained, upstreamSha=upstream, stableRelease=releases["tag_name"])
    if ancestor(root, upstream, maintained) and not validate_current:
        report["state"] = "unchanged"
        output("changed", "false")
        return
    existing = git(root, "ls-remote", "--heads", "origin", f"refs/heads/{INTEGRATION}")
    if existing:
        git(root, "fetch", "origin", f"refs/heads/{INTEGRATION}")
        existing = sha(git(root, "rev-parse", "FETCH_HEAD"))
        # An unrelated branch must not be silently adopted by the automation.
        record = json.loads(git(root, "show", f"{existing}:{RECORD}"))
        if record.get("maintainedBranch") != MAINTAINED or not ancestor(root, sha(record["maintainedBaseSha"]), existing):
            raise ValueError("Existing integration branch has unexpected ownership/history")
    merge_candidate(root, maintained, upstream, existing or None)
    lock = json.loads((root / "mpv-build.lock.json").read_text())
    if lock["repo"] != "edde746/mpv-build":
        raise ValueError("Native repository changed; review required")
    native_versions = api(f"repos/edde746/mpv-build/contents/versions.json?ref={sha(lock['commit'])}")
    components = json.loads(base64.b64decode(native_versions["content"]))["components"]
    update_manifest(root, maintained, upstream, releases["tag_name"], components)
    git(root, "add", MANIFEST, RECORD, ".github/workflows/livesync-dart.yml", ".github/workflows/livesync-macos.yml")
    git(root, "diff", "--cached", "--check")
    git(root, "commit", "-m", f"chore(livesync): prepare upstream {upstream[:12]}", "-m",
        "Preserve the maintained patch history and record the upstream-selected build inputs.\nValidation and promotion remain separate.")
    candidate = sha(git(root, "rev-parse", "HEAD"))
    # A normal push rejects a concurrent remote update. Never force either branch.
    git(root, "push", "origin", f"HEAD:refs/heads/{INTEGRATION}")
    report.update(state="candidate", candidateSha=candidate, branch=INTEGRATION, exercise=validate_current)
    mark_pr_pending(candidate)
    output("changed", "true")
    output("sha", candidate)


def matching_run(runs, candidate):
    eligible = [r for r in runs if r["head_sha"] == candidate and r["event"] == "workflow_dispatch"
                and r.get("display_title") == f"LiveSync upstream {candidate}"]
    live = [r for r in eligible if r["status"] != "completed"]
    if len(live) > 1:
        raise ValueError("Multiple live runs match the candidate; refusing ambiguous reuse")
    if live:
        return live[0]
    successful = [r for r in eligible if r.get("conclusion") == "success"]
    return max(successful, key=lambda r: r["id"], default=None)


def validate(candidate, kind, report, native_run=None):
    sha(candidate)
    branch = api(f"repos/{FORK}/git/ref/heads/{INTEGRATION}")
    if branch["object"]["sha"] != candidate:
        raise ValueError("Integration branch moved before dispatch")
    workflow = WORKFLOWS[kind]
    path = f"repos/{FORK}/actions/workflows/{workflow}/runs?" + urlencode({
        "branch": INTEGRATION, "event": "workflow_dispatch", "per_page": 100,
    })
    previous = api(path)["workflow_runs"]
    selected = matching_run(previous, candidate)
    if selected and selected["status"] == "completed" and kind != "checks":
        artifacts = api(f"repos/{FORK}/actions/runs/{selected['id']}/artifacts")["artifacts"]
        if not artifacts or any(a["expired"] for a in artifacts):
            selected = None
    if selected is None:
        args = ["gh", "workflow", "run", workflow, "--repo", FORK, "--ref", INTEGRATION,
                "-f", f"integration_id={candidate}"]
        if kind == "native":
            args += ["-f", "windows=true", "-f", "macos=false"]
        if kind == "windows":
            if native_run is None or not re.fullmatch(r"[0-9]+", native_run):
                raise ValueError("Windows validation requires its verified native run")
            args += ["-f", f"run_id={native_run}"]
        run(*args)
        previous_ids = {r["id"] for r in previous}
        deadline = time.monotonic() + 120
        while selected is None and time.monotonic() < deadline:
            candidates = [r for r in api(path)["workflow_runs"]
                          if r["id"] not in previous_ids and r["head_sha"] == candidate
                          and r.get("display_title") == f"LiveSync upstream {candidate}"]
            if len(candidates) > 1:
                raise ValueError("Multiple newly dispatched runs; refusing ambiguous selection")
            selected = candidates[0] if candidates else None
            if selected is None:
                time.sleep(5)
        if selected is None:
            raise RuntimeError("Dispatch observation timed out; inspect existing runs before retrying")
    run_id = selected["id"]
    report.update(candidateSha=candidate, kind=kind, runId=run_id, url=selected["html_url"])
    output("run_id", run_id)
    deadline = time.monotonic() + (345 if kind == "native" else 85) * 60
    while time.monotonic() < deadline:
        current = api(f"repos/{FORK}/actions/runs/{run_id}")
        if current["head_sha"] != candidate:
            raise ValueError("Validation run does not match the immutable candidate")
        report.update(status=current["status"], conclusion=current["conclusion"])
        if current["status"] == "completed":
            if current["conclusion"] != "success":
                raise RuntimeError(f"{kind} validation failed: {current['html_url']}")
            return
        time.sleep(30)
    raise RuntimeError(f"Validation still pending: {selected['html_url']}; run was not cancelled")


def publish_pr(candidate, report, evidence_dir):
    sha(candidate)
    if api(f"repos/{FORK}/git/ref/heads/{INTEGRATION}")["object"]["sha"] != candidate:
        raise ValueError("Integration branch moved after validation")
    records = [json.loads(p.read_text()) for p in evidence_dir.rglob("*.json")]
    verified = {r.get("kind"): r for r in records if r.get("candidateSha") == candidate and r.get("conclusion") == "success"}
    if set(verified) != set(WORKFLOWS):
        raise ValueError("Missing successful exact-SHA validation evidence")
    for kind, record in verified.items():
        actual = api(f"repos/{FORK}/actions/runs/{int(record['runId'])}")
        if (actual["head_sha"] != candidate or actual["conclusion"] != "success"
                or actual["path"] != f".github/workflows/{WORKFLOWS[kind]}"
                or actual.get("display_title") != f"LiveSync upstream {candidate}"):
            raise ValueError("Live GitHub validation state disagrees with preserved evidence")
        record["url"] = actual["html_url"]
    lines = [f"Integration candidate `{candidate}`. The maintained branch has not been changed.", "",
             "## Validation", "", *[f"- [{kind}]({verified[kind]['url']})" for kind in WORKFLOWS], "",
             "Native application and provenance artifacts are attached to the linked Windows/macOS runs.",
             "These automated checks do not establish audible playback, Mentalist accuracy or performance budgets.", "",
             "## Promotion", "", "Review the exact candidate and use a merge commit, without squashing or rebasing. "
             "If the maintained branch moves, rerun integration and validate the merged candidate before promotion. "
             "Do not force-push the maintained branch. No public release is created."]
    body = evidence_dir / "pull-request.md"
    body.write_text("\n".join(lines) + "\n")
    prs = integration_prs()
    args = ["gh", "pr", "edit", str(prs[0]["number"])] if prs else ["gh", "pr", "create", "--draft", "--base", MAINTAINED, "--head", INTEGRATION]
    report["pullRequest"] = run(*args, "--repo", FORK, "--title", "chore: integrate upstream into LiveSync",
                                "--body-file", str(body))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("prepare", "validate", "publish"))
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--sha")
    parser.add_argument("--kind", choices=WORKFLOWS)
    parser.add_argument("--native-run")
    parser.add_argument("--evidence", type=Path)
    parser.add_argument("--validate-current", action="store_true")
    args = parser.parse_args()
    report = {"checkedAt": datetime.now(timezone.utc).isoformat()}
    try:
        if args.operation == "prepare":
            prepare(Path.cwd(), report, args.validate_current)
        elif args.operation == "validate":
            validate(args.sha, args.kind, report, args.native_run)
        else:
            publish_pr(args.sha, report, args.evidence)
    except IntegrationConflict as error:
        report.update(state="conflict", files=error.files)
        raise
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
