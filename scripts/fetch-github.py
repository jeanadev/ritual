#!/usr/bin/env python3
"""
fetch-github.py
Pulls two data sets from GitHub:
  1. Open issues assigned to you in the org (REST search — fast)
  2. Open PRs where your review has been requested

Auth: Fine-grained personal access token stored in config/.env
Required scopes: Issues (read), Pull requests (read)
"""

import os
import sys
import warnings
warnings.filterwarnings("ignore", category=DeprecationWarning, module="urllib3")
from pathlib import Path
from dotenv import load_dotenv

SCRIPT_DIR = Path(__file__).parent
ROOT_DIR = SCRIPT_DIR.parent
ENV_FILE = ROOT_DIR / "config" / ".env"

load_dotenv(ENV_FILE)

GITHUB_TOKEN = os.getenv("GITHUB_TOKEN")
GITHUB_ORG = os.getenv("GITHUB_ORG")
GITHUB_USERNAME = os.getenv("GITHUB_USERNAME")
GITHUB_TEAM = os.getenv("GITHUB_TEAM")

REST_SEARCH_URL = "https://api.github.com/search/issues"

HEADERS = {
    "Authorization": f"Bearer {GITHUB_TOKEN}",
    "Accept": "application/vnd.github+json",
}


def validate_config():
    missing = [v for v in ["GITHUB_TOKEN", "GITHUB_ORG", "GITHUB_USERNAME"] if not os.getenv(v)]
    if missing:
        print(f"ERROR: Missing env vars: {', '.join(missing)}\nAdd them to {ENV_FILE}", file=sys.stderr)
        sys.exit(1)


def rest_search(query):
    import requests
    try:
        response = requests.get(
            REST_SEARCH_URL,
            params={"q": query, "per_page": 20, "sort": "updated", "order": "desc"},
            headers=HEADERS,
            timeout=15,
        )
        response.raise_for_status()
        return response.json().get("items", [])
    except requests.exceptions.RequestException as e:
        print(f"GitHub REST error: {e}", file=sys.stderr)
        return []


def fetch_my_issues():
    items = rest_search(f"org:{GITHUB_ORG} is:issue is:open assignee:{GITHUB_USERNAME}")
    return [{"number": i["number"], "title": i["title"], "repo": i["repository_url"].split("/")[-1]} for i in items]


def fetch_review_requested_prs():
    """
    Fetch PRs where GITHUB_USERNAME is explicitly listed as a requested reviewer
    (not just via team membership). Requires a per-PR call to check reviewer list.
    """
    import requests

    # Cast a wide net first via search, then filter to direct tags only
    candidates = rest_search(f"org:{GITHUB_ORG} is:pr is:open -is:draft review-requested:{GITHUB_USERNAME}")

    direct = []
    for pr in candidates:
        # Parse repo owner/name from repository_url
        # e.g. https://api.github.com/repos/org/repo-name
        repo_path = pr["repository_url"].replace("https://api.github.com/repos/", "")
        reviewers_url = f"https://api.github.com/repos/{repo_path}/pulls/{pr['number']}/requested_reviewers"

        try:
            resp = requests.get(reviewers_url, headers=HEADERS, timeout=10)
            resp.raise_for_status()
            data = resp.json()
            user_logins = [u["login"].lower() for u in data.get("users", [])]
            team_slugs = [t["slug"].lower() for t in data.get("teams", [])]
            if GITHUB_USERNAME.lower() in user_logins or (GITHUB_TEAM and GITHUB_TEAM.lower() in team_slugs):
                direct.append(pr)
        except Exception:
            # If we can't verify, include it rather than silently drop
            direct.append(pr)

    return [{"number": i["number"], "title": i["title"], "repo": i["repository_url"].split("/")[-1], "url": i["html_url"]} for i in direct]


def main():
    validate_config()
    lines = []

    try:
        issues = fetch_my_issues()
        lines.append("### Issues — assigned to me (open)")
        if issues:
            for i in issues:
                lines.append(f"- #{i['number']} — {i['title']} — {i['repo']}")
        else:
            lines.append("- (no open issues assigned to you)")
    except Exception as e:
        lines.append(f"### Issues\n- ⚠️  Fetch failed: {e}")

    lines.append("")

    try:
        prs = fetch_review_requested_prs()
        lines.append("### PRs — review requested from me or my team")
        if prs:
            for p in prs:
                lines.append(f"- PR #{p['number']} — {p['title']} — {p['repo']} — {p['url']}")
        else:
            lines.append("- (no open PRs with your review requested)")
    except Exception as e:
        lines.append(f"### PRs\n- ⚠️  Fetch failed: {e}")

    print("\n".join(lines))


if __name__ == "__main__":
    main()
