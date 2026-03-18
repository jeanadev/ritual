# Daily Ritual Workflow — Architecture Document

**Status:** v1.0 — Built and running  
**Owner:** Design Lead / Accessibility Specialist  
**Stack:** zsh + Python + Anthropic API or GitHub Copilot CLI + Google Calendar API + GitHub REST API  
**Goal:** Bookend workday with AI-assisted planning (morning) and structured reflection (evening)

---

## What this is

Two shell commands that together form a daily ritual:

```
start-workday  →  brain dump + calendar + GitHub → Claude or Copilot → daily note (opens in VS Code)
end-workday    →  3 questions → frontmatter → carry-forward + 1:1 notes
```

All data lives as plain markdown files you own and control. No third-party note app. No dashboard. The LLM provider is swappable between Claude and GitHub Copilot.

---

## System Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                        MORNING                              │
│                                                             │
│  Google Calendar API ──┐                                    │
│                        │                                    │
│  GitHub REST API ───────┼──► start-workday.sh ──► Claude API │
│                        │                           or        │
│  Brain dump (typed) ───┘                      GitHub Copilot │
│                                                       │     │
│                                                   response   │
│  "What's on your mind?"                               │     │
│                                               daily-note.md │
│                                               (opens in     │
│                                                VS Code)     │
└─────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────┐
│                        EVENING                              │
│                                                             │
│  end-workday.sh                                             │
│       │                                                     │
│       ├── "one word for your day?"                          │
│       ├── "most important thing accomplished?"              │
│       ├── "most important thing tomorrow?"                  │
│       │          ↓                                          │
│       │   written to daily note as YAML frontmatter         │
│       │   "tomorrow" → injected into next morning           │
│       │                                                     │
│       └── 1:1 detection (if applicable)                     │
│              ↓                                              │
│          carry-forward notes per person                     │
│          → surfaced on day of next 1:1                      │
└─────────────────────────────────────────────────────────────┘
```

---

## File Structure

```
~/ritual/
├── scripts/
│   ├── start-workday.sh        # Morning entry point
│   ├── end-workday.sh          # Evening entry point
│   ├── fetch-calendar.py       # Google Calendar API pull
│   ├── fetch-github.py         # GitHub REST API pull
│   └── prompt-template.md      # Manual Phase 1 template
├── notes/
│   ├── YYYY-MM-DD.md           # Daily notes (one per day)
│   └── 1on1/
│       └── [name].md           # Per-person 1:1 carry-forward notes
├── config/
│   ├── .env                    # API keys (never committed)
│   ├── .env.example            # Template
│   └── settings.json           # Tunable parameters
├── .gitignore
└── README.md
```

---

## Data Sources

### Brain Dump (Morning)
- **What it is:** Free-text prompt at the start of `start-workday` — "What's on your mind?"
- **Input method:** Type freely, hit return twice when done
- **Storage:** Ephemeral by design — not saved verbatim. The writing does its job (processing, decompressing) and the signal survives into the briefing output
- **Briefing model's job:** Cross-reference against calendar and GitHub to surface gaps — things on your mind that aren't on your schedule, or schedule pressure that conflicts with what you're actually worried about

### Google Calendar
- **Auth:** OAuth 2.0 via Google Cloud Console (one-time setup)
- **Scope:** `calendar.readonly`
- **Pull:** Today's events, 6am–7pm window, excluding all-day/OOO events
- **Output:** Time-blocked list with back-to-back flags and deep work window detection

**Setup reality:** The Google Cloud Console flow has changed from older documentation. Current path: Credentials → Create Credentials → Credential type: User data → OAuth Client ID → Desktop app. Scopes screen can be skipped — the script requests the scope at runtime. Budget 45–60 minutes the first time; most of it is waiting on Google's UI.

### GitHub
- **Auth:** Fine-grained personal access token
- **Scopes needed:** Issues (read), Pull requests (read) — both under Repository permissions. Projects (read) under Organization permissions is vestigial and no longer used.
- **Issues:** REST search — `org:ORG is:issue is:open assignee:USERNAME` — fast regardless of project size
- **PRs:** REST search filtered to direct `@username` tags and designated a11y team, with per-PR reviewer verification to exclude broader team membership noise. Draft PRs excluded.

**What we tried first:** GitHub Projects v2 GraphQL. Rejected because the org has thousands of issues and paginating the entire project timed out. REST search returns results in seconds and is simpler to maintain.

**PR filtering detail:** GitHub's search API resolves team membership, so `review-requested:username` returns PRs tagged via any team the user belongs to. The script makes a secondary call to `/pulls/{number}/requested_reviewers` for each result and keeps only PRs where the username appears directly in `users` OR the designated a11y team slug appears in `teams`. This filters out broad org-team noise while keeping both direct and a11y-team requests.

### Briefing provider
- **Selection:** `config/settings.json` → `briefing.provider`
- **Shared input:** System prompt + calendar block + GitHub block + brain dump + yesterday's "tomorrow" note + any 1:1 carry-forwards
- **Output:** Plain markdown briefing, max 400 words

#### Claude
- **Model:** Configurable via `briefing.anthropic_model` (default `claude-sonnet-4-20250514`)
- **Call type:** Single `/v1/messages` POST per morning
- **Auth:** `ANTHROPIC_API_KEY` in `config/.env`

#### GitHub Copilot CLI
- **Model:** Configurable via `briefing.copilot_model` (default `gpt-5.4`)
- **Call type:** Single non-interactive `gh copilot -p ... -s` run per morning
- **Auth:** Copilot CLI login plus active Copilot entitlement

**Implementation note:** Both provider paths use temp files (`mktemp`) when moving multiline prompt/response content through shell. This avoids newline and quoting failures from interpolating rich text directly into shell command strings.

---

## Prompt Architecture

### Morning system prompt

```
You are a focused daily briefing assistant. Given a brain dump, a calendar,
and a list of open GitHub issues and PRs, produce a structured daily note.

Output format — markdown, max 400 words:

## Schedule
List today's events as time blocks. Flag back-to-back sequences,
meeting-heavy days, and where the only deep work windows are.

## Focus (Top 3)
Derive from: GitHub priority + calendar breathing room + anything surfaced
in the brain dump that isn't already captured. Number them. Include issue/PR
number and title where applicable.

## Risk Flags
Surface: back-to-back meetings, overloaded day, unresolved blockers,
review queue pressure, or tension between what's scheduled and what's
actually on the person's mind.

## Carry-Forward
If a carry-forward note is provided, quote it verbatim with source date.
Omit if none.

## 1:1 Prep (only if 1:1 notes are provided)
If carry-forward notes exist for a 1:1 happening today, surface them
under the person's name. Omit entirely if no 1:1 notes.

Cross-reference the brain dump against the calendar and issues. If something
is on the person's mind but not on their schedule or issue list, flag it
explicitly. If something is scheduled but the brain dump suggests it's not
the real priority, name the tension. Tone: direct, no filler.
```

### PR list — not summarized by the briefing model

The 400-word briefing limit encourages summarization and can drop PR URLs. The PR review queue is appended to the daily note verbatim, after the model-generated briefing, so links are always preserved. This is a separate `## PR Review Queue` section at the bottom of the note — raw output from `fetch-github.py`, not touched by the model.

### Evening prompts

Three questions, no API call:

1. Describe your day in one word
2. Most important thing you accomplished today
3. Most important thing you need to do tomorrow

Written as YAML frontmatter to today's note. The `tomorrow` field is injected into the next morning's briefing as carry-forward.

### Paper bridge

Everything else from the day — paper notes, scribbles, thinking-out-loud — stays on paper and gets released. No digitizing, no guilt. The `tomorrow` field is the only thing that crosses into the digital system, because it has a specific job the next morning.

---

## 1:1 Carry-Forward Loop

At end of day, `end-workday` re-fetches the raw calendar (not the model summary — the briefing reformats meeting names) and checks for exact title matches against a local 1:1 map in `config/oneone-map.zsh`. If a match is found, it prompts for carry-forward notes per person.

Notes are saved to `notes/1on1/[name].md` with a date header.

On the morning of the next 1:1, `start-workday` detects the meeting in the raw calendar output and injects the last entry from that person's file into the briefing under **1:1 Prep**.

**Why exact titles instead of pattern matching:** Calendar event names like `Name / Name` are common defaults in Google Calendar and would generate false positives. Exact string matching against a local config map is more reliable and easier to maintain.

**Why re-fetch calendar at end of day:** The briefing reformats meeting names. Scanning the daily note for meeting names would miss matches. The raw calendar output always contains exact titles.

---

## Design Decisions & Rationale

### GitHub REST over Projects v2 GraphQL
The original architecture assumed GraphQL against GitHub Projects v2 for richer iteration/status context. In practice, the org has thousands of issues and paginating the entire project timed out at any page size. REST search (`/search/issues`) is indexed by GitHub, returns in seconds, and gives sufficient signal for a daily briefing. The loss of iteration/status filtering is acceptable — the briefing model synthesizes down to top 3 regardless.

### Brain dump as a first-class input
Calendar and GitHub data only reflect what's scheduled — not what's actually weighing on you. The gap between those two things is often where the day's real friction lives. Adding the brain dump as a third input lets the briefing model surface tensions that neither data source would catch alone.

### Ephemeral brain dump
The dump is not stored verbatim. This is intentional. The writing does its job (processing, decompressing) and the signal survives into the briefing. Storing it would add retrieval pressure and change the nature of the writing.

### Minimal evening questions
Three questions, 30 seconds. The value compounds through the carry-forward loop and, eventually, pattern lookback. Scope was deliberately not expanded — more questions would reduce completion rate.

### No PKM system
Obsidian, Notion, PARA, and similar tools were considered and rejected. The owner uses notes for processing and externalizing, not retrieval or knowledge building. Plain markdown files in a folder are sufficient and keep data owner-controlled.

### VS Code as the reading surface
Terminal scroll is a poor reading surface for a daily briefing. Adding `code "$NOTE_FILE"` at the end of `start-workday.sh` opens the note automatically each morning. One line, no extra tooling.

### Personal GitHub account, local git config
The ritual repo lives on a personal GitHub account separate from the work account used daily. A repo-local `git config user.name` and `git config user.email` override the global work config inside `~/ritual/` only. No SSH key complexity, no account switching — just directory-scoped config.

---

## What Was Planned vs. What Was Built

| Original plan | What actually shipped |
|---|---|
| GitHub Projects v2 GraphQL | GitHub REST search — faster, simpler |
| Filter to active iteration + status | All open assigned issues — model synthesizes |
| Phase 1 manual validation first | Built everything day one, ran in parallel |
| PR list summarized by model | PR list appended verbatim to preserve URLs |
| No 1:1 support | 1:1 carry-forward loop added same day |

---

## Build Log — What We Hit

- **Google OAuth flow changed** — current UI uses "User data" credential type, not the older "Desktop app" direct path
- **Python 3.9 urllib SSL hang** — system Python on macOS has SSL issues with GitHub's GraphQL endpoint; switched to `requests` library
- **GraphQL timeout** — thousands of issues in the org made project pagination unworkable; rewrote to use REST search
- **Shell heredoc JSON parsing** — API response newlines break `json.loads("""$RESPONSE""")` in shell heredocs; fixed by writing response to temp file
- **PR filter noise** — GitHub search resolves team membership, returning more PRs than desired; added per-PR reviewer verification
- **1:1 detection from daily note** — the briefing reformats meeting names, breaking pattern matching; fixed by re-fetching raw calendar at end of day
- **Google API warnings to stdout** — third-party library warnings polluted calendar output and broke grep-based detection; suppressed with `2>/dev/null` in shell calls

---

## Phase Status

### Phase 1 — Manual validation ✓
Completed in parallel with Phase 2. Prompt template built and usable standalone in claude.ai.

### Phase 2 — Scripted morning ✓
- [x] Google Cloud project + Calendar API enabled
- [x] OAuth credentials, token cached in `config/token.json`
- [x] `fetch-calendar.py` — live calendar with back-to-back and deep work detection
- [x] GitHub fine-grained token with Issues + Pull requests read
- [x] `fetch-github.py` — assigned issues + scoped PR queue via REST
- [x] `start-workday.sh` — full pipeline, provider call, opens in VS Code

### Phase 3 — Scripted evening ✓
- [x] `end-workday.sh` — 3 questions, YAML frontmatter
- [x] Carry-forward wired — `tomorrow` field injected into next morning
- [x] 1:1 loop — detect meetings, capture notes, surface on next 1:1 day
- [x] Frontmatter parseable for future pattern analysis

### Phase 4 — Claude Code (optional, future)
Not started. Hold until Phase 1–3 prove behavioral value over time.

---

## Risk Log

| Risk | Status | Notes |
|------|--------|-------|
| Google OAuth setup blocks momentum | ✓ Resolved | Took ~45 min; Google's UI has changed from older docs |
| Briefing format doesn't change behavior | Active | Validate over first 2 weeks |
| GitHub token expires | Active | Fine-grained token, document renewal when it expires |
| Daily note files accumulate with no review habit | Active | Monthly lookback not yet designed |
| Over-engineering before proving value | ✓ Resolved | System is running; value TBD |

---

## Open Questions

- **Pattern lookback:** The real long-term value is monthly/quarterly review of frontmatter. Schema supports this now. Automation deferred.
- **Notifications:** No system notification on briefing completion — just opens VS Code. May want a macOS notification if the workflow shifts away from terminal-first.
- **Python version:** Scripts run on system Python 3.9 with deprecation warnings from Google's libraries. Upgrading to Python 3.11+ via pyenv or brew would clean this up.

---

## Not In Scope (v1)

- Slack/email triage as part of the briefing
- Automated weekly or monthly summaries
- LLM-based end-of-day cleanup
- Claude Code slash commands (Phase 4, deferred)

---

## References

- [Anthropic API docs](https://docs.anthropic.com)
- [Google Calendar API Python quickstart](https://developers.google.com/calendar/api/quickstart/python)
- [GitHub REST API — Search issues](https://docs.github.com/en/rest/search/search#search-issues-and-pull-requests)
- [GitHub fine-grained personal access tokens](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens)
- [GitHub requested reviewers API](https://docs.github.com/en/rest/pulls/review-requests)
- [Claude Code docs](https://docs.anthropic.com/en/docs/claude-code)
