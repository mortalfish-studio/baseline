"""Summarise GitHub notifications and review requests as bounded JSON.

Uses the already-authenticated gh CLI. Every string is length-capped and
every URL is rebuilt as https://github.com/... or dropped.
"""
import json
import re
import subprocess

MAX_ITEMS = 15
MAX_TEXT = 140
REPO = re.compile(r"^[A-Za-z0-9_.-]{1,100}/[A-Za-z0-9_.-]{1,100}$")
API_SUBJECT = re.compile(r"^https://api\.github\.com/repos/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/(pulls|issues|commits|releases|discussions)/([A-Za-z0-9]{1,64})$")
HTML_URL = re.compile(r"^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/(pull|issues)/\d{1,9}$")


def text(value):
    value = " ".join(str(value or "").split())
    return value[:MAX_TEXT]


def gh(*args):
    out = subprocess.run(["gh", *args], capture_output=True, text=True, timeout=20)
    if out.returncode != 0:
        raise RuntimeError(out.stderr.strip()[:200] or "gh failed")
    if len(out.stdout) > 2_000_000:
        raise RuntimeError("response too large")
    return json.loads(out.stdout or "null")


def subject_url(subject):
    match = API_SUBJECT.match(str(subject.get("url") or ""))
    if not match:
        return "https://github.com/notifications"
    repo, kind, ident = match.groups()
    kind = {"pulls": "pull", "commits": "commit", "releases": "releases"}.get(kind, kind)
    if kind == "releases":
        return f"https://github.com/{repo}/releases"
    return f"https://github.com/{repo}/{kind}/{ident}"


def main():
    result = {"ok": True, "notifications": 0, "items": [], "reviews": []}
    try:
        notes = gh("api", "notifications?per_page=50") or []
        result["notifications"] = len(notes)
        for note in notes[:MAX_ITEMS]:
            repo = str((note.get("repository") or {}).get("full_name") or "")
            subject = note.get("subject") or {}
            result["items"].append({
                "repo": repo if REPO.match(repo) else "",
                "title": text(subject.get("title")),
                "kind": text(subject.get("type"))[:20],
                "url": subject_url(subject),
            })
        prs = gh("search", "prs", "--review-requested=@me", "--state=open",
                 "--json", "title,url,repository,number", "--limit", str(MAX_ITEMS)) or []
        for pr in prs[:MAX_ITEMS]:
            url = str(pr.get("url") or "")
            repo = str((pr.get("repository") or {}).get("nameWithOwner") or "")
            result["reviews"].append({
                "repo": repo if REPO.match(repo) else "",
                "title": text(pr.get("title")),
                "number": int(pr.get("number") or 0),
                "url": url if HTML_URL.match(url) else "https://github.com/pulls/review-requested",
            })
    except Exception as error:  # noqa: BLE001 - report any failure to the widget
        result = {"ok": False, "error": text(error)}
    print(json.dumps(result))


main()
