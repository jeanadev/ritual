#!/usr/bin/env zsh
# configure-provider.sh
# Helper to select the morning briefing provider without hand-editing JSON.
#
# Usage:
#   ./configure-provider.sh
#   ./configure-provider.sh claude
#   ./configure-provider.sh copilot

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
CONFIG_DIR="$ROOT_DIR/config"
SETTINGS_FILE="$CONFIG_DIR/settings.json"
ENV_FILE="$CONFIG_DIR/.env"

BOLD='\033[1m'
RESET='\033[0m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'

usage() {
  cat <<'EOF'
Usage: scripts/configure-provider.sh [claude|copilot]

If no argument is provided, the script will prompt you to choose a provider.
EOF
}

pick_provider() {
  local choice

  echo ""
  echo "${BOLD}Choose your morning briefing provider:${RESET}"
  echo "  1) Claude"
  echo "  2) Copilot"
  echo ""
  printf "Enter 1 or 2: "
  read -r choice

  case "$choice" in
    1) echo "claude" ;;
    2) echo "copilot" ;;
    *)
      echo "ERROR: Please enter 1 or 2." >&2
      exit 1
      ;;
  esac
}

case "${1:-}" in
  "")
    PROVIDER=$(pick_provider)
    ;;
  claude|copilot)
    PROVIDER="$1"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac

mkdir -p "$CONFIG_DIR"

python3 - "$SETTINGS_FILE" "$PROVIDER" <<'PYEOF'
import json
import sys
from pathlib import Path

settings_path = Path(sys.argv[1])
provider = sys.argv[2]

settings = {}
if settings_path.exists():
    try:
        settings = json.loads(settings_path.read_text())
    except json.JSONDecodeError as e:
        print(f"ERROR: config/settings.json is malformed: {e}\nDelete it and re-run this script to recreate it.", file=sys.stderr)
        sys.exit(1)

briefing = settings.setdefault("briefing", {})
briefing["provider"] = provider
briefing.setdefault("anthropic_model", "claude-sonnet-4-20250514")
briefing.setdefault("copilot_model", "gpt-5.4")
briefing.setdefault("max_tokens", 1024)

calendar = settings.setdefault("calendar", {})
calendar.setdefault("day_start_hour", 7)
calendar.setdefault("day_start_minute", 30)
calendar.setdefault("day_end_hour", 17)
calendar.setdefault("day_end_minute", 30)
calendar.setdefault("back_to_back_gap_minutes", 15)
calendar.setdefault("deep_work_min_minutes", 60)

github = settings.setdefault("github", {})
github.setdefault("active_statuses", ["ready to work", "in progress"])

settings_path.write_text(json.dumps(settings, indent=2) + "\n")
PYEOF

echo ""
echo "${GREEN}✓ Briefing provider set to ${PROVIDER}${RESET}"
echo "${DIM}Updated: config/settings.json${RESET}"

if [[ "$PROVIDER" == "claude" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo ""
    echo "${YELLOW}Next:${RESET} copy config/.env.example to config/.env and add ANTHROPIC_API_KEY."
  elif ! grep -q '^ANTHROPIC_API_KEY=' "$ENV_FILE"; then
    echo ""
    echo "${YELLOW}Next:${RESET} add ANTHROPIC_API_KEY to config/.env."
  else
    echo ""
    echo "${DIM}Next: confirm ANTHROPIC_API_KEY in config/.env is valid.${RESET}"
  fi
else
  if command -v gh >/dev/null 2>&1; then
    echo ""
    echo "${DIM}Next: run 'gh copilot' once and complete login if you have not already.${RESET}"
  else
    echo ""
    echo "${YELLOW}Next:${RESET} install GitHub CLI and run 'gh copilot' once to complete login."
  fi
fi

echo ""
