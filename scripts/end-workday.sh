#!/usr/bin/env zsh
# end-workday.sh
# Evening entry point. Prompts 3 reflection questions, appends answers
# as YAML frontmatter to today's daily note. Detects 1:1s and prompts
# for carry-forward notes.
#
# Usage: ./end-workday.sh

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
NOTES_DIR="$ROOT_DIR/notes"
ONEONE_DIR="$ROOT_DIR/notes/1on1"

TODAY=$(date +%Y-%m-%d)
NOTE_FILE="$NOTES_DIR/$TODAY.md"

BOLD='\033[1m'
RESET='\033[0m'
DIM='\033[2m'
GREEN='\033[0;32m'

echo ""
echo "${BOLD}— end workday — $TODAY —${RESET}"
echo ""

# ── 1. Three questions ─────────────────────────────────────────────────────────

echo "${BOLD}Describe your day in one word:${RESET}"
read -r DAY_WORD

echo ""
echo "${BOLD}Most important thing you accomplished today?${RESET}"
read -r WIN

echo ""
echo "${BOLD}Most important thing you need to do tomorrow?${RESET}"
read -r TOMORROW

# ── 2. Write to daily note ─────────────────────────────────────────────────────

if [[ ! -f "$NOTE_FILE" ]]; then
  echo ""
  echo "${DIM}No daily note found for today — creating one.${RESET}"
  mkdir -p "$NOTES_DIR"
  cat > "$NOTE_FILE" <<NOTEOF
---
date: $TODAY
day_word: $DAY_WORD
win: $WIN
tomorrow: $TOMORROW
---

# Daily Note — $TODAY

(Created at end of day — no morning briefing generated)
NOTEOF
else
  # Write answers to a temp JSON file to safely handle quotes and special characters
  ANSWERS_FILE=$(mktemp /tmp/ritual-answers.XXXXXX.json)
  python3 -c "
import json, sys
data = {'day_word': sys.argv[1], 'win': sys.argv[2], 'tomorrow': sys.argv[3], 'today': sys.argv[4]}
open(sys.argv[5], 'w').write(json.dumps(data))
" "$DAY_WORD" "$WIN" "$TOMORROW" "$TODAY" "$ANSWERS_FILE"

  python3 - "$NOTE_FILE" "$ANSWERS_FILE" << 'PYEOF'
import re, sys, json

note_path = sys.argv[1]
answers_file = sys.argv[2]

with open(answers_file) as f:
    a = json.load(f)

day_word = a["day_word"]
win = a["win"]
tomorrow = a["tomorrow"]
today = a["today"]

with open(note_path, "r") as f:
    content = f.read()

fm_pattern = re.compile(r"^(---\n)(.*?)(---\n)", re.DOTALL)
match = fm_pattern.match(content)

if not match:
    new_fm = f"---\ndate: {today}\nday_word: {day_word}\nwin: {win}\ntomorrow: {tomorrow}\n---\n"
    content = new_fm + content
else:
    fm_body = match.group(2)
    fm_body = re.sub(r"^day_word:.*$", f"day_word: {day_word}", fm_body, flags=re.MULTILINE)
    fm_body = re.sub(r"^win:.*$", f"win: {win}", fm_body, flags=re.MULTILINE)
    fm_body = re.sub(r"^tomorrow:.*$", f"tomorrow: {tomorrow}", fm_body, flags=re.MULTILINE)
    content = match.group(1) + fm_body + match.group(3) + content[match.end():]

with open(note_path, "w") as f:
    f.write(content)

print("ok")
PYEOF

  rm -f "$ANSWERS_FILE"
fi

# ── 3. 1:1 notes (if applicable) ──────────────────────────────────────────────

# Exact calendar title → person name mapping
# Update if meeting names change
declare -A ONEONE_MAP=(
  ["Raquel / Jeana"]="Raquel"
  ["Dan / Jeana"]="Dan"
  ["Jamie / Jeana"]="Jamie"
  ["David / Jeana"]="David"
  ["Erin / Jeana"]="Erin"
  ["Barb / Jeana"]="Barb"
)

# Re-fetch today's raw calendar (stderr suppressed — warnings only)
RAW_CALENDAR=$(python3 "$SCRIPT_DIR/fetch-calendar.py" 2>/dev/null || echo "")

ONEONE_NAMES=()
for TITLE in "${(@k)ONEONE_MAP}"; do
  if echo "$RAW_CALENDAR" | grep -qF "$TITLE"; then
    ONEONE_NAMES+=("${ONEONE_MAP[$TITLE]}")
  fi
done

if [[ ${#ONEONE_NAMES[@]} -gt 0 ]]; then
  echo ""
  echo "${BOLD}1:1 notes${RESET}"
  mkdir -p "$ONEONE_DIR"

  for NAME in "${ONEONE_NAMES[@]}"; do
    echo ""
    echo "${BOLD}Carry-forward notes for $NAME? (blank to skip)${RESET}"
    read -r ONEONE_NOTE
    if [[ -n "$ONEONE_NOTE" ]]; then
      ONEONE_FILE="$ONEONE_DIR/${NAME:l}.md"
      echo "" >> "$ONEONE_FILE"
      echo "## $TODAY" >> "$ONEONE_FILE"
      echo "$ONEONE_NOTE" >> "$ONEONE_FILE"
      echo "${DIM}  → saved to 1on1/${NAME:l}.md${RESET}"
    fi
  done
fi

# ── 4. Confirm ─────────────────────────────────────────────────────────────────

echo ""
echo "${GREEN}✓ Logged to notes/$TODAY.md${RESET}"
echo "${DIM}Tomorrow's carry-forward: \"$TOMORROW\"${RESET}"
echo ""
echo "Rest. The rest stays on paper."
echo ""
