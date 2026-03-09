#!/usr/bin/env zsh
# start-workday.sh
# Morning entry point. Collects brain dump, fetches calendar + GitHub,
# calls Anthropic API, writes today's daily note.
#
# Usage: ./start-workday.sh
# Or from anywhere if added to PATH or aliased.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
CONFIG_DIR="$ROOT_DIR/config"
NOTES_DIR="$ROOT_DIR/notes"
SCRIPTS_DIR="$ROOT_DIR/scripts"

# Load env
if [[ -f "$CONFIG_DIR/.env" ]]; then
  set -a
  source "$CONFIG_DIR/.env"
  set +a
else
  echo "ERROR: config/.env not found. Copy config/.env.example and fill it in." >&2
  exit 1
fi

: "${ANTHROPIC_API_KEY:?ERROR: ANTHROPIC_API_KEY not set in config/.env}"

TODAY=$(date +%Y-%m-%d)
NOTE_FILE="$NOTES_DIR/$TODAY.md"
SETTINGS_FILE="$CONFIG_DIR/settings.json"

# Colors (safe for terminals that support them)
BOLD='\033[1m'
RESET='\033[0m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'

mkdir -p "$NOTES_DIR"

echo ""
echo "${BOLD}— start workday — $TODAY —${RESET}"
echo ""

# ── 1. Brain dump ──────────────────────────────────────────────────────────────

echo "${BOLD}What's on your mind?${RESET}"
echo "${DIM}Type freely. Hit return twice when done.${RESET}"
echo ""

BRAIN_DUMP=""
while IFS= read -r line; do
  [[ -z "$line" && -z "$BRAIN_DUMP" ]] && continue  # skip leading blank lines
  [[ -z "$line" ]] && break                           # blank line = done
  BRAIN_DUMP+="$line"$'\n'
done

if [[ -z "$BRAIN_DUMP" ]]; then
  BRAIN_DUMP="(no brain dump provided)"
fi

# ── 2. Fetch calendar ──────────────────────────────────────────────────────────

echo ""
echo "${DIM}Fetching calendar...${RESET}"
CALENDAR_BLOCK=$(python3 "$SCRIPTS_DIR/fetch-calendar.py" 2>/tmp/ritual-cal-err.txt) || {
  echo "${YELLOW}⚠️  Calendar fetch failed. Continuing without it.${RESET}"
  echo "Error: $(cat /tmp/ritual-cal-err.txt)"
  CALENDAR_BLOCK="(calendar unavailable — fetch failed)"
}

# ── 3. Fetch GitHub ────────────────────────────────────────────────────────────

echo "${DIM}Fetching GitHub...${RESET}"
GITHUB_BLOCK=$(python3 "$SCRIPTS_DIR/fetch-github.py" 2>/tmp/ritual-gh-err.txt) || {
  echo "${YELLOW}⚠️  GitHub fetch failed. Continuing without it.${RESET}"
  echo "Error: $(cat /tmp/ritual-gh-err.txt)"
  GITHUB_BLOCK="(GitHub unavailable — fetch failed)"
}

# Extract just the PR section for verbatim append to note
PR_BLOCK=$(echo "$GITHUB_BLOCK" | awk '/^### PRs/,0')

# ── 4. Carry-forward from last working day ───────────────────────────────────
# Looks back up to 4 days to handle weekends and long weekends

CARRY_FORWARD=""

for DAYS_BACK in 1 2 3 4; do
  PAST_DATE=$(date -v-${DAYS_BACK}d +%Y-%m-%d 2>/dev/null || date -d "${DAYS_BACK} days ago" +%Y-%m-%d)
  PAST_NOTE="$NOTES_DIR/$PAST_DATE.md"
  if [[ -f "$PAST_NOTE" ]]; then
    TOMORROW_VALUE=$(awk '/^---/{f++} f==1 && /^tomorrow:/{sub(/^tomorrow: */, ""); print; exit}' "$PAST_NOTE")
    if [[ -n "$TOMORROW_VALUE" ]]; then
      CARRY_FORWARD="\"$TOMORROW_VALUE\"\n— from $PAST_DATE"
      break
    fi
  fi
done

if [[ -z "$CARRY_FORWARD" ]]; then
  CARRY_FORWARD="(none)"
fi

# ── 4b. 1:1 carry-forwards ────────────────────────────────────────────────────

ONEONE_DIR="$NOTES_DIR/1on1"
ONEONE_BLOCK=""

# Known 1:1 meetings — must match start-workday and end-workday
declare -A ONEONE_MAP=(
  ["Raquel / Jeana"]="Raquel"
  ["Dan / Jeana"]="Dan"
  ["Jamie / Jeana"]="Jamie"
  ["David / Jeana"]="David"
  ["Erin / Jeana"]="Erin"
  ["Barb / Jeana"]="Barb"
)

# Check raw calendar output for exact 1:1 title matches
for TITLE in "${(@k)ONEONE_MAP}"; do
  NAME="${ONEONE_MAP[$TITLE]}"
  ONEONE_FILE="$ONEONE_DIR/${NAME:l}.md"
  if echo "$CALENDAR_BLOCK" | grep -qF "$TITLE" && [[ -f "$ONEONE_FILE" ]]; then
    LAST_NOTE=$(awk '/^## /{found=1; header=$0; body=""} found && !/^## /{body=body"
"$0} END{if(header) print header body}' "$ONEONE_FILE" | tail -20)
    if [[ -n "$LAST_NOTE" ]]; then
      ONEONE_BLOCK+="### 1:1 with $NAME
$LAST_NOTE
"
    fi
  fi
done

# ── 5. Build prompt ────────────────────────────────────────────────────────────

SYSTEM_PROMPT="You are a focused daily briefing assistant. Given a brain dump, a calendar, and a list of open GitHub issues and PRs, produce a structured daily note.

Output format — markdown, max 400 words:

## Schedule
List today's events as time blocks. Flag back-to-back sequences, meeting-heavy days, and where the only deep work windows are.

## Focus (Top 3)
Derive from: GitHub priority + calendar breathing room + anything surfaced in the brain dump that isn't already captured. Number them. Include issue/PR number and title where applicable.

## Risk Flags
Surface: back-to-back meetings, overloaded day, unresolved blockers, review queue pressure, or tension between what's scheduled and what's actually on the person's mind.

## Carry-Forward
If a carry-forward note is provided and it's not '(none)', quote it verbatim and include the source date. If none, omit this section entirely.

## 1:1 Prep (only if 1:1 notes are provided)
If carry-forward notes exist for a 1:1 happening today, surface them under the person's name. One section per person. Omit entirely if no 1:1 notes are provided.

Cross-reference the brain dump against the calendar and issues. If something is on the person's mind but not on their schedule or issue list, flag it explicitly. If something is scheduled but the brain dump suggests it's not the real priority, name the tension. Tone: direct, no filler."

USER_CONTENT="Today's date: $TODAY

### Calendar
$CALENDAR_BLOCK

### GitHub
$GITHUB_BLOCK

### Brain dump
$BRAIN_DUMP

### Carry-forward from yesterday
$CARRY_FORWARD

### 1:1 notes from last meeting
${ONEONE_BLOCK:-"(no 1:1s today)"}"

# ── 6. Call Anthropic API ──────────────────────────────────────────────────────

echo "${DIM}Generating briefing...${RESET}"

# Build JSON payload using Python (avoids jq dependency, handles escaping safely)
PAYLOAD=$(python3 - <<PYEOF
import json, sys

system = """$SYSTEM_PROMPT"""
user = """$USER_CONTENT"""

payload = {
    "model": "claude-sonnet-4-20250514",
    "max_tokens": 1024,
    "system": system,
    "messages": [{"role": "user", "content": user}]
}

print(json.dumps(payload))
PYEOF
)

RESPONSE_FILE=$(mktemp /tmp/ritual-response.XXXXXX.json)

curl -s -X POST "https://api.anthropic.com/v1/messages" \
  -H "x-api-key: $ANTHROPIC_API_KEY" \
  -H "anthropic-version: 2023-06-01" \
  -H "content-type: application/json" \
  -d "$PAYLOAD" \
  -o "$RESPONSE_FILE"

# Extract text content from response
BRIEFING=$(python3 - "$RESPONSE_FILE" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    response = json.load(f)

if "error" in response:
    print(f"API ERROR: {response['error']['message']}", file=sys.stderr)
    sys.exit(1)

content = response.get("content", [])
text = "\n\n".join(block["text"] for block in content if block.get("type") == "text")
print(text)
PYEOF
) || {
  echo "ERROR: Anthropic API call failed." >&2
  cat "$RESPONSE_FILE" >&2
  rm -f "$RESPONSE_FILE"
  exit 1
}

rm -f "$RESPONSE_FILE"

# ── 7. Write daily note ────────────────────────────────────────────────────────

# Frontmatter shell — evening script will fill in day_word, win, tomorrow
cat > "$NOTE_FILE" <<NOTEOF
---
date: $TODAY
day_word:
win:
tomorrow:
---

# Daily Note — $TODAY

$BRIEFING

---

## PR Review Queue

$PR_BLOCK
NOTEOF

# ── 8. Display ─────────────────────────────────────────────────────────────────

echo ""
echo "${GREEN}✓ Briefing written to notes/$TODAY.md${RESET}"
echo ""
echo "────────────────────────────────────────"
cat "$NOTE_FILE" | grep -v "^---" | grep -v "^date:" | grep -v "^day_word:" | grep -v "^win:" | grep -v "^tomorrow:"
echo "────────────────────────────────────────"
echo ""
code "$NOTE_FILE"
