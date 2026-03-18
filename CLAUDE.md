# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A two-command workday bookend. `start-workday` fetches calendar + GitHub, collects a brain dump, and writes a structured daily note (via AI or raw automation). `end-workday` collects 3 reflection answers and carries them forward to tomorrow.

## Running the scripts

```zsh
./scripts/start-workday.sh   # morning
./scripts/end-workday.sh     # evening
```

No build step. No package manager. Pure zsh + Python 3.

```zsh
# Check prerequisites without changing anything
./scripts/first-run.sh --check

# Switch AI provider (claude | copilot | automation)
./scripts/configure-provider.sh

# Set GitHub identity for this repo
./scripts/configure-github-account.sh

# Test calendar/GitHub fetch independently
python3 scripts/fetch-calendar.py
python3 scripts/fetch-github.py
```

## Architecture

```
start-workday.sh
  ├── fetch-calendar.py      → $CALENDAR_BLOCK
  ├── fetch-github.py        → $GITHUB_BLOCK, $PR_BLOCK
  ├── Look back 1–4 days     → $CARRY_FORWARD (from YAML frontmatter `tomorrow:` field)
  ├── Check oneone-map.zsh   → $ONEONE_BLOCK (last entry per person from notes/1on1/[name].md)
  ├── Prompt brain dump      → $BRAIN_DUMP
  └── Provider branch:
        claude     → POST https://api.anthropic.com/v1/messages → $BRIEFING
        copilot    → gh copilot CLI → $BRIEFING
        automation → assemble raw sections directly → $BRIEFING
  → writes notes/YYYY-MM-DD.md, opens in VS Code

end-workday.sh
  ├── Prompt 3 questions     → day_word, win, tomorrow
  ├── Write YAML frontmatter → today's note
  └── Detect 1:1s via oneone-map.zsh → prompt carry-forward → append to notes/1on1/[name].md
```

## Configuration

**`config/settings.json`** — all tunable parameters:
- `briefing.provider`: `"claude"` | `"copilot"` | `"automation"`
- `briefing.anthropic_model`, `briefing.copilot_model`, `briefing.max_tokens`
- `calendar.day_start_hour/minute`, `day_end_hour/minute`, `back_to_back_gap_minutes`, `deep_work_min_minutes`
- `github.active_statuses`

**`config/.env`** — secrets (never committed): `ANTHROPIC_API_KEY`, `GITHUB_TOKEN`, `GITHUB_ORG`, `GITHUB_USERNAME`, `GITHUB_TEAM`

**`config/oneone-map.zsh`** — zsh associative array mapping exact Google Calendar event titles to person names. Keys are case-sensitive and must match exactly.

## Key conventions

- Multiline shell variables passed to Python via `mktemp` temp files to avoid quoting issues — do not inline large strings directly in shell commands.
- `$PR_BLOCK` is extracted verbatim from `$GITHUB_BLOCK` and appended to the note separately from the AI briefing — it always shows raw data regardless of provider.
- The `automation` provider branch builds `$BRIEFING` directly in zsh without calling any external API; the same `$NOTE_FILE` write path is used for all three providers.
- YAML frontmatter in daily notes (`notes/YYYY-MM-DD.md`) is written in two passes: `start-workday` writes the shell with empty fields, `end-workday` fills them in via Python regex replacement.
- `config/oneone-map.zsh` and `config/.env` are local-only (gitignored). Changes to these files should never be committed.
