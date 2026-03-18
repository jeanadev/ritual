# daily-ritual

Two-command workday bookend: structured morning briefing + lightweight evening reflection.

```
start-workday  →  brain dump + calendar + GitHub → Claude, Copilot, or none → daily note (opens in VS Code)
end-workday    →  3 questions → frontmatter → carry-forward loop + 1:1 notes
```

Full architecture: see `daily-ritual-architecture.md` (keep alongside this folder).

---

## Setup

### 1. Place this folder

```zsh
mv ritual ~/ritual
cd ~/ritual
```

### 2. First run

Recommended:

```zsh
./scripts/first-run.sh
```

You can also pick a provider up front:

```zsh
./scripts/first-run.sh claude
./scripts/first-run.sh copilot
```

To verify prerequisites without changing anything:

```zsh
./scripts/first-run.sh --check
```

`first-run.sh` installs Python dependencies, creates `config/.env` if needed, makes the scripts executable, and routes you through provider setup.

### 3. Python dependencies

```zsh
pip3 install google-auth-oauthlib google-auth-httplib2 google-api-python-client python-dotenv requests
```

### 4. Config

```zsh
cp config/.env.example config/.env
```

Set the repo-local GitHub account for this repository:

```zsh
./scripts/configure-github-account.sh --username your-username --org your-org --project-number your-project-number
```

Or run it with no arguments for prompts:

```zsh
./scripts/configure-github-account.sh
```

This repo uses `config/.env` as its GitHub API identity, so switching this file does not affect your other GitHub account setup elsewhere on the machine. `ANTHROPIC_API_KEY` is required only if you keep the Claude provider.

### 5. Choose your briefing provider

Use the helper:

```zsh
./scripts/configure-provider.sh
```

Or set it directly:

```json
"briefing": {
  "provider": "claude"
}
```

Set `"provider"` to:

- `"claude"` to call Anthropic directly
- `"copilot"` to generate the briefing with GitHub Copilot CLI via `gh copilot`
- `"none"` to skip AI entirely — calendar, GitHub, carry-forward, and 1:1 prep are still fetched and written to the note as raw data

Optional model settings also live in `config/settings.json`:

```json
"briefing": {
  "provider": "copilot",
  "anthropic_model": "claude-sonnet-4-20250514",
  "copilot_model": "gpt-5.4",
  "max_tokens": 1024
}
```

### 6. GitHub token

GitHub → Settings → Developer Settings → Personal access tokens → Fine-grained tokens

- Resource owner: your org
- Repository access: All repositories (or select relevant ones)
- Permissions needed:
  - Issues: Read (under Repository permissions)
  - Pull requests: Read (under Repository permissions)
  - Projects: Read (under Organization permissions)

Paste the token for the selected repo-local GitHub account into `config/.env` as `GITHUB_TOKEN`.

**Note:** `GITHUB_PROJECT_NUMBER` is in `.env.example` for reference but is no longer used — the GitHub fetch uses REST search, not Projects v2 GraphQL.

### 7. Copilot login (only if using `briefing.provider = "copilot"`)

GitHub Copilot mode requires an active Copilot subscription and an authenticated CLI session.

```zsh
gh copilot
```

If prompted, complete the login flow in the Copilot CLI. `gh copilot` will download the CLI automatically if needed.

### 8. Google Calendar OAuth (allow 60–90 min the first time)

1. Go to [console.cloud.google.com](https://console.cloud.google.com)
2. Create a new project
3. Enable the **Google Calendar API**
4. Go to Credentials → Create Credentials → Credential type: **User data** → OAuth 2.0 Client ID
5. Fill in app name and contact email. Skip scopes. Application type: **Desktop app**
6. Download the JSON → save as `config/credentials.json`
7. Run once manually to authorize:
   ```zsh
   python3 scripts/fetch-calendar.py
   ```
   A browser window will open. Log in and authorize. Token is cached in `config/token.json`.

After first run, token refreshes automatically.

### 9. Make scripts executable

```zsh
chmod +x scripts/start-workday.sh scripts/end-workday.sh scripts/configure-provider.sh scripts/configure-github-account.sh scripts/first-run.sh
```

### 10. Shell aliases (recommended)

Add to your `~/.zshrc`:

```zsh
alias start-workday="~/ritual/scripts/start-workday.sh"
alias end-workday="~/ritual/scripts/end-workday.sh"
```

Then `source ~/.zshrc`.

### 11. Configure your 1:1s

Copy the local template if `first-run.sh` has not already done it:

```zsh
cp config/oneone-map.zsh.example config/oneone-map.zsh
```

Then edit `config/oneone-map.zsh` to match your exact Google Calendar meeting titles:

```zsh
declare -gA ONEONE_MAP=(
  ["Person / YourName"]="Person"
)
```

The key is the exact calendar event title (or unique substring). The value is the display name used for prompts and file names.

---

## Daily use

**Morning:**
```zsh
start-workday
```
- Type your brain dump, hit return twice when done
- Calendar and GitHub are fetched automatically
- Your selected provider generates a structured briefing
- Daily note written to `notes/YYYY-MM-DD.md` and opened in VS Code
- Note includes a verbatim **PR Review Queue** section with links at the bottom

**Evening:**
```zsh
end-workday
```
- Answer 3 questions (one word, win, tomorrow)
- Answers written to today's note as YAML frontmatter
- `tomorrow` field injected into tomorrow's morning briefing
- If you had any 1:1s today, prompted for carry-forward notes per person

---

## GitHub PR filtering

PRs are filtered to only those where you are requested as a reviewer directly by username or via your designated a11y team (`platform-design-system-a11y`). Draft PRs are excluded. Broader org team requests are excluded.

To change the team filter, edit `fetch-github.py`:

```python
if GITHUB_USERNAME.lower() in user_logins or "your-team-slug" in team_slugs:
```

---

## 1:1 carry-forwards

When `end-workday` detects a 1:1 on today's calendar, it prompts for carry-forward notes per person. Notes saved to `notes/1on1/[name].md`.

On the morning of the next 1:1, `start-workday` detects the meeting, loads the last entry from that person's file, and injects it into the briefing under a **1:1 Prep** section.

The `notes/1on1/` directory is created automatically on first use.

---

## File structure

```
ritual/
├── scripts/
│   ├── start-workday.sh       # Morning entry point
│   ├── end-workday.sh         # Evening entry point
│   ├── fetch-calendar.py      # Google Calendar pull (OAuth)
│   ├── fetch-github.py        # GitHub issues + PR review queue (REST)
│   └── prompt-template.md     # Manual Phase 1 template (no-code version)
├── notes/
│   ├── YYYY-MM-DD.md          # Daily notes (auto-generated)
│   └── 1on1/
│       └── [name].md          # Per-person 1:1 carry-forward notes
├── config/
│   ├── .env                   # API keys — never commit
│   ├── .env.example           # Template
│   ├── settings.json          # Tunable parameters
│   ├── credentials.json       # Google OAuth app credentials — never commit
│   └── token.json             # Google OAuth token (auto-generated) — never commit
├── .gitignore
└── README.md
```

---

## .gitignore

```
config/.env
config/credentials.json
config/token.json
notes/
```

---

## Troubleshooting

**Calendar fetch fails:** Check that `config/credentials.json` exists and the Calendar API is enabled. Re-run `python3 scripts/fetch-calendar.py` manually to re-authorize.

**GitHub fetch hangs:** The script uses REST search, not GraphQL pagination — should return in seconds. Check your token is valid and has Issues + Pull requests read permissions.

**Copilot briefing fails:** Run `gh copilot` once manually and complete login. Confirm you have an active Copilot subscription and that `config/settings.json` has `"provider": "copilot"`.

**GitHub PR list includes unwanted team-tagged PRs:** Set `GITHUB_TEAM=your-team-slug` in `config/.env` to match your team exactly. If `GITHUB_TEAM` is not set, only direct review requests (where you are tagged individually) are included.

**1:1 prompts not appearing:** The calendar event title must exactly match a key in `config/oneone-map.zsh`. Match is case-sensitive.

**Claude API key error:** Confirm `ANTHROPIC_API_KEY` starts with `sk-ant-` and is active at console.anthropic.com, or switch `briefing.provider` to `"copilot"` or `"none"` if you do not want to use Anthropic.

**Want to run without any AI:** Run `./scripts/configure-provider.sh` and select option 3, or set `"provider": "none"` in `config/settings.json`. All automation runs normally; the note will contain your brain dump, raw calendar, and GitHub data instead of an AI-generated briefing.

**Daily note doesn't update in VS Code:** VS Code doesn't auto-reload externally modified files. Close and reopen the file after running `end-workday`.

---

## Acknowledgments

Inspired by [Jesse Gardner](https://www.linkedin.com/posts/plasticmind_every-morning-i-type-start-workday-into-activity-7434806560742207488-b7lO) whose LinkedIn post about his `start-workday` workflow started this whole thing.
