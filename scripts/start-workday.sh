#!/usr/bin/env zsh
# start-workday.sh
# Morning entry point. Collects brain dump, fetches calendar + GitHub,
# generates a briefing via the configured provider, writes today's daily note.
#
# Usage: ./start-workday.sh
# Or from anywhere if added to PATH or aliased.

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
CONFIG_DIR="$ROOT_DIR/config"
NOTES_DIR="$ROOT_DIR/notes"
SCRIPTS_DIR="$ROOT_DIR/scripts"

LOCAL_TIMEZONE=$(date +%Z)
TODAY=$(date +%Y-%m-%d)

get_past_date() {
  local days_back="$1"

  if date -d "${days_back} days ago" +%Y-%m-%d >/dev/null 2>&1; then
    date -d "${days_back} days ago" +%Y-%m-%d
  else
    date -v-"${days_back}"d +%Y-%m-%d
  fi
}

# Load env
if [[ -f "$CONFIG_DIR/.env" ]]; then
  set -a
  source "$CONFIG_DIR/.env"
  set +a
else
  echo "ERROR: config/.env not found. Copy config/.env.example and fill it in." >&2
  exit 1
fi

NOTE_FILE="$NOTES_DIR/$TODAY.md"
SETTINGS_FILE="$CONFIG_DIR/settings.json"

# Load briefing settings
read -r BRIEFING_PROVIDER ANTHROPIC_MODEL COPILOT_MODEL BRIEFING_MAX_TOKENS <<EOF
$(python3 - "$SETTINGS_FILE" <<'PYEOF'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
if settings_path.exists():
    try:
        settings = json.loads(settings_path.read_text())
    except json.JSONDecodeError as e:
        print(f"ERROR: config/settings.json is malformed: {e}\nFix or delete it and re-run ./scripts/configure-provider.sh", file=sys.stderr)
        sys.exit(1)
else:
    settings = {}
briefing = settings.get("briefing", {})

provider = str(briefing.get("provider", "claude")).strip().lower() or "claude"
anthropic_model = str(briefing.get("anthropic_model", "claude-sonnet-4-20250514")).strip()
copilot_model = str(briefing.get("copilot_model", "gpt-5.4")).strip()
max_tokens = int(briefing.get("max_tokens", 1024))

print(provider, anthropic_model, copilot_model, max_tokens)
PYEOF
)
EOF

case "$BRIEFING_PROVIDER" in
  claude|copilot|automation) ;;
  *)
    echo "ERROR: briefing.provider must be 'claude', 'copilot', or 'automation' in config/settings.json." >&2
    exit 1
    ;;
esac

if [[ "$BRIEFING_PROVIDER" == "claude" ]]; then
  : "${ANTHROPIC_API_KEY:?ERROR: ANTHROPIC_API_KEY not set in config/.env}"
fi

# Colors (safe for terminals that support them)
BOLD='\033[1m'
RESET='\033[0m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'

CLEANUP_FILES=()
trap 'rm -f "${CLEANUP_FILES[@]}"' EXIT

mkdir -p "$NOTES_DIR"

echo ""
echo "${BOLD}— start workday — $TODAY ($LOCAL_TIMEZONE) —${RESET}"
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

CAL_ERR_FILE=$(mktemp /tmp/ritual-cal-err.XXXXXX.txt)
CLEANUP_FILES+=("$CAL_ERR_FILE")

echo ""
echo "${DIM}Fetching calendar...${RESET}"
CALENDAR_BLOCK=$(python3 "$SCRIPTS_DIR/fetch-calendar.py" 2>"$CAL_ERR_FILE") || {
  echo "${YELLOW}⚠️  Calendar fetch failed. Continuing without it.${RESET}"
  echo "Error: $(cat "$CAL_ERR_FILE")"
  CALENDAR_BLOCK="(calendar unavailable — fetch failed)"
}

# ── 3. Fetch GitHub ────────────────────────────────────────────────────────────

GH_ERR_FILE=$(mktemp /tmp/ritual-gh-err.XXXXXX.txt)
CLEANUP_FILES+=("$GH_ERR_FILE")

echo "${DIM}Fetching GitHub...${RESET}"
GITHUB_BLOCK=$(python3 "$SCRIPTS_DIR/fetch-github.py" 2>"$GH_ERR_FILE") || {
  echo "${YELLOW}⚠️  GitHub fetch failed. Continuing without it.${RESET}"
  echo "Error: $(cat "$GH_ERR_FILE")"
  GITHUB_BLOCK="(GitHub unavailable — fetch failed)"
}

# Split GitHub output so automation mode can avoid duplicating the PR queue.
GITHUB_MAIN_BLOCK=$(echo "$GITHUB_BLOCK" | awk 'BEGIN{in_prs=0} /^### PRs/{in_prs=1} !in_prs{print}')
# Extract just the PR section for verbatim append to note
PR_BLOCK=$(echo "$GITHUB_BLOCK" | awk '/^### PRs/,0')

# ── 4. Carry-forward from last working day ───────────────────────────────────
# Looks back up to 4 days to handle weekends and long weekends

CARRY_FORWARD=""

for DAYS_BACK in 1 2 3 4; do
  PAST_DATE=$(get_past_date "$DAYS_BACK")
  PAST_NOTE="$NOTES_DIR/$PAST_DATE.md"
  if [[ -f "$PAST_NOTE" ]]; then
    TOMORROW_VALUE=$(python3 - "$PAST_NOTE" <<'PYEOF'
import re, sys
content = open(sys.argv[1], encoding="utf-8-sig").read().replace("\r\n", "\n").lstrip("\n")
match = re.match(r"^---\n(.*?)\n---\n", content, re.DOTALL)
if match:
    for line in match.group(1).splitlines():
        if line.startswith("tomorrow:"):
            print(line[len("tomorrow:"):].strip())
            break
PYEOF
)
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
ONEONE_MAP_FILE="$CONFIG_DIR/oneone-map.zsh"

# Known 1:1 meetings come from local config and must match start-workday/end-workday.
declare -A ONEONE_MAP=()
if [[ -f "$ONEONE_MAP_FILE" ]]; then
  source "$ONEONE_MAP_FILE"
fi

# Check raw calendar output for exact 1:1 title matches
for TITLE in "${(@k)ONEONE_MAP}"; do
  NAME="${ONEONE_MAP[$TITLE]}"
  ONEONE_FILE="$ONEONE_DIR/${NAME:l}.md"
  if echo "$CALENDAR_BLOCK" | grep -qF "$TITLE" && [[ -f "$ONEONE_FILE" ]]; then
    LAST_NOTE=$(awk '
      /^## / {header=$0; body=""; next}
      header {body = body $0 ORS}
      END {if (header) printf "%s\n%s", header, body}
    ' "$ONEONE_FILE" | tail -20)
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
One bullet per event, format: - TIME–TIME — Event title. Each event on its own line, no grouping or summarizing. After the list, add a single line flagging back-to-back sequences, meeting-heavy days, and deep work windows.

## Focus (Top 3)
Derive from: GitHub priority + calendar breathing room + anything surfaced in the brain dump that isn't already captured. Number them. Include issue/PR number and title where applicable.

## Risk Flags
One bullet per risk, format: - **Short label**: Explanation. Each risk on its own line. Surface: back-to-back meetings, overloaded day, unresolved blockers, review queue pressure, or tension between what's scheduled and what's actually on the person's mind.

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


# ── 6. Generate briefing via selected provider ────────────────────────────────

if [[ "$BRIEFING_PROVIDER" == "automation" ]]; then
  echo "${DIM}Skipping AI briefing (provider=automation). Writing raw data to note.${RESET}"

  CARRY_SECTION=""
  if [[ "$CARRY_FORWARD" != "(none)" ]]; then
    CARRY_SECTION="## Carry-Forward

$CARRY_FORWARD"
  fi

  ONEONE_SECTION=""
  if [[ -n "$ONEONE_BLOCK" ]]; then
    ONEONE_SECTION="## 1:1 Prep

$ONEONE_BLOCK"
  fi

  BRIEFING="## Brain Dump

$BRAIN_DUMP

## Schedule

$CALENDAR_BLOCK

## GitHub

$GITHUB_MAIN_BLOCK"

  if [[ -n "$CARRY_SECTION" ]]; then
    BRIEFING="$BRIEFING

$CARRY_SECTION"
  fi

  if [[ -n "$ONEONE_SECTION" ]]; then
    BRIEFING="$BRIEFING

$ONEONE_SECTION"
  fi

else

echo "${DIM}Generating briefing with ${BRIEFING_PROVIDER}...${RESET}"

PROMPT_FILE=$(mktemp /tmp/ritual-prompt.XXXXXX.json)
CLEANUP_FILES+=("$PROMPT_FILE")
python3 -c "
import json, sys
data = {'system': sys.argv[1], 'user': sys.argv[2]}
open(sys.argv[3], 'w').write(json.dumps(data))
" "$SYSTEM_PROMPT" "$USER_CONTENT" "$PROMPT_FILE"

if [[ "$BRIEFING_PROVIDER" == "claude" ]]; then
  PAYLOAD=$(python3 - "$PROMPT_FILE" "$ANTHROPIC_MODEL" "$BRIEFING_MAX_TOKENS" << 'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

payload = {
    "model": sys.argv[2],
    "max_tokens": int(sys.argv[3]),
    "system": data["system"],
    "messages": [{"role": "user", "content": data["user"]}]
}

print(json.dumps(payload))
PYEOF
  )

  RESPONSE_FILE=$(mktemp /tmp/ritual-response.XXXXXX.json)
  CLEANUP_FILES+=("$RESPONSE_FILE")

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
    exit 1
  }

else
  if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not found. Install GitHub CLI to use briefing.provider=copilot." >&2
    exit 1
  fi

  COPILOT_PROMPT_FILE=$(mktemp /tmp/ritual-copilot-prompt.XXXXXX.txt)
  CLEANUP_FILES+=("$COPILOT_PROMPT_FILE")
  python3 - "$PROMPT_FILE" "$COPILOT_PROMPT_FILE" <<'PYEOF'
import json, sys

with open(sys.argv[1]) as f:
    data = json.load(f)

prompt = (
    "You are generating a daily briefing for a local shell workflow.\n"
    "Do not use tools, do not edit files, and do not explain your process.\n"
    "Return only the final markdown briefing.\n\n"
    f"SYSTEM:\n{data['system']}\n\nUSER:\n{data['user']}\n"
)

with open(sys.argv[2], "w") as f:
    f.write(prompt)
PYEOF

  COPILOT_ERR_FILE=$(mktemp /tmp/ritual-copilot-err.XXXXXX.txt)
  CLEANUP_FILES+=("$COPILOT_ERR_FILE")
  BRIEFING=$(env -u GITHUB_TOKEN -u GH_TOKEN -u COPILOT_GITHUB_TOKEN gh copilot \
    --model "$COPILOT_MODEL" \
    --disable-builtin-mcps \
    --no-custom-instructions \
    --no-ask-user \
    --available-tools= \
    -s \
    -p "$(cat "$COPILOT_PROMPT_FILE")" \
    2>"$COPILOT_ERR_FILE") || {
      echo "ERROR: GitHub Copilot CLI call failed." >&2
      cat "$COPILOT_ERR_FILE" >&2
      exit 1
    }

fi

fi # end provider block

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
