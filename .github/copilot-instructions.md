# Copilot Instructions

## Commands

This repo does not define a formal build, lint, or automated test suite. Validate changes with the executable workflow that exists:

```bash
# one-time setup
./scripts/first-run.sh

# read-only setup verification
./scripts/first-run.sh --check

# switch this repo to a different GitHub account
./scripts/configure-github-account.sh --username your-username --org your-org --project-number your-project-number

pip3 install google-auth-oauthlib google-auth-httplib2 google-api-python-client python-dotenv requests
cp config/.env.example config/.env
chmod +x scripts/start-workday.sh scripts/end-workday.sh
```

```bash
# targeted validation for the calendar integration
python3 scripts/fetch-calendar.py

# targeted validation for the GitHub integration
python3 scripts/fetch-github.py

# syntax-check the shell entry points
zsh -n scripts/start-workday.sh
zsh -n scripts/end-workday.sh
zsh -n scripts/configure-provider.sh
zsh -n scripts/configure-github-account.sh
zsh -n scripts/first-run.sh

# end-to-end morning flow
zsh scripts/start-workday.sh

# end-to-end evening flow
zsh scripts/end-workday.sh
```

There is no single-test command; the closest equivalent is running just the script you changed.

## Architecture

This repository is a local, file-based workday ritual rather than a packaged application. The main workflow is split between two shell entry points and two Python data fetchers:

- `scripts/start-workday.sh` is the morning orchestrator. It loads `config/.env`, reads `config/settings.json` to choose the briefing provider, collects a brain dump, runs the calendar and GitHub fetchers, pulls forward the last non-empty `tomorrow:` value from recent daily notes, injects any relevant 1:1 carry-forward notes, generates the briefing with Claude or GitHub Copilot, writes `notes/YYYY-MM-DD.md`, appends a verbatim `## PR Review Queue`, and opens the note in VS Code.
- `scripts/configure-provider.sh` is the install/setup helper for provider choice. It updates `config/settings.json` while preserving the rest of the runtime settings and prints provider-specific next steps.
- `scripts/configure-github-account.sh` is the repo-local GitHub identity helper. It updates `config/.env` for this repository only and clears `GITHUB_TOKEN` if the GitHub username changes, so the wrong account token is not silently reused.
- `scripts/first-run.sh` is the bootstrap entry point for a fresh install. It installs Python dependencies, seeds `config/.env` if missing, marks the scripts executable, and then delegates provider choice to `scripts/configure-provider.sh`.
- `scripts/first-run.sh --check` is the non-destructive readiness check. Use it when you need to verify prerequisites or local setup state without editing files or installing packages.
- 1:1 names and meeting titles belong in `config/oneone-map.zsh`, which is local-only and gitignored. Do not hardcode personal names in the committed shell scripts.
- `scripts/end-workday.sh` is the evening orchestrator. It collects three reflection answers, writes or updates YAML frontmatter in today’s note, re-fetches raw calendar output to detect 1:1 meetings, and appends carry-forward notes to `notes/1on1/<name>.md`.
- `scripts/fetch-calendar.py` owns Google Calendar OAuth plus schedule analysis. It reads calendar thresholds from `config/settings.json`, excludes all-day events, flags back-to-back meetings, and emits deep-work windows as plain text for the shell scripts to consume.
- `scripts/fetch-github.py` owns GitHub data collection. It uses REST search for open assigned issues and review-requested PRs, then makes a per-PR `requested_reviewers` call so the PR queue only keeps direct reviewer requests plus the designated a11y team slug.

The persistent data model is plain markdown under `notes/`. Daily notes contain YAML frontmatter plus the generated briefing. Per-person 1:1 carry-forward notes live under `notes/1on1/`.

## Conventions

- Keep scripts runnable from any working directory. Existing scripts resolve paths from `${0:A:h}` in zsh and `Path(__file__).parent` in Python instead of assuming the current directory.
- Preserve the daily note frontmatter shape exactly: `date`, `day_word`, `win`, and `tomorrow`. `start-workday.sh` seeds blank values; `end-workday.sh` updates those keys in place.
- Treat the brain dump as ephemeral input. The workflow intentionally passes it to the model but does not save it separately outside the generated briefing.
- Keep `ONEONE_MAP` in `start-workday.sh` and `end-workday.sh` in sync. 1:1 detection is based on exact calendar title matches, not fuzzy matching.
- Preserve the split between model-generated briefing text and raw PR data. The `## PR Review Queue` section is appended verbatim from `fetch-github.py` so links are not lost to summarization.
- When passing rich text or API responses through shell, follow the existing temp-file pattern instead of embedding multiline JSON directly in shell variables. Both shell scripts rely on Python helpers plus `mktemp` to avoid quote/newline breakage.
- `fetch-calendar.py` and `fetch-github.py` are consumed by shell via stdout, so avoid adding non-data prints to stdout. If warnings are unavoidable, send them to stderr.
- `config/settings.json` is the tunable runtime config file in the repo; calendar window, deep-work thresholds, and briefing provider/model selection belong there instead of being hardcoded elsewhere.
