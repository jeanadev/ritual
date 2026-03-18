#!/usr/bin/env zsh
# first-run.sh
# Bootstrap local setup for the ritual workflow.
#
# Usage:
#   ./scripts/first-run.sh
#   ./scripts/first-run.sh claude
#   ./scripts/first-run.sh copilot
#   ./scripts/first-run.sh --check

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
CONFIG_DIR="$ROOT_DIR/config"
ENV_EXAMPLE="$CONFIG_DIR/.env.example"
ENV_FILE="$CONFIG_DIR/.env"
CONFIGURE_PROVIDER_SCRIPT="$SCRIPT_DIR/configure-provider.sh"
CONFIGURE_GITHUB_ACCOUNT_SCRIPT="$SCRIPT_DIR/configure-github-account.sh"

BOLD='\033[1m'
RESET='\033[0m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'

usage() {
  cat <<'EOF'
Usage: scripts/first-run.sh [claude|copilot|--check]

Runs local bootstrap for this repo:
- installs Python dependencies
- seeds config/.env if missing
- makes scripts executable
- lets you choose Claude or Copilot

Use --check to verify local prerequisites and setup state without changing anything.
EOF
}

print_check_line() {
  local label="$1"
  local state="$2"
  local detail="$3"
  printf "%-24s %s  %s\n" "$label" "$state" "$detail"
}

case "${1:-}" in
  ""|claude|copilot)
    PROVIDER_ARG="${1:-}"
    ;;
  --check)
    CHECK_ONLY=1
    PROVIDER_ARG=""
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

: "${CHECK_ONLY:=0}"

if [[ "$CHECK_ONLY" == "1" ]]; then
  echo ""
  echo "${BOLD}— ritual setup check —${RESET}"
  echo ""

  FAILURES=0

  if command -v python3 >/dev/null 2>&1; then
    print_check_line "python3" "ok" "$(python3 --version 2>&1)"
  else
    print_check_line "python3" "missing" "Install Python 3."
    FAILURES=$((FAILURES + 1))
  fi

  if command -v pip3 >/dev/null 2>&1; then
    print_check_line "pip3" "ok" "$(pip3 --version 2>&1)"
  else
    print_check_line "pip3" "missing" "Install pip3."
    FAILURES=$((FAILURES + 1))
  fi

  if [[ -f "$ENV_FILE" ]]; then
    print_check_line "config/.env" "ok" "Present"
  else
    print_check_line "config/.env" "missing" "Run ./scripts/first-run.sh to create it from the template."
    FAILURES=$((FAILURES + 1))
  fi

  if [[ -f "$CONFIG_DIR/credentials.json" ]]; then
    print_check_line "credentials.json" "ok" "Present"
  else
    print_check_line "credentials.json" "missing" "Add Google OAuth desktop-app credentials."
    FAILURES=$((FAILURES + 1))
  fi

  if [[ -f "$CONFIG_DIR/token.json" ]]; then
    print_check_line "token.json" "ok" "Present"
  else
    print_check_line "token.json" "missing" "Run python3 scripts/fetch-calendar.py once to authorize."
  fi

  if [[ -f "$CONFIG_DIR/settings.json" ]]; then
    PROVIDER_STATE=$(python3 - "$CONFIG_DIR/settings.json" <<'PYEOF'
import json, sys
from pathlib import Path
try:
    settings = json.loads(Path(sys.argv[1]).read_text())
except json.JSONDecodeError as e:
    print(f"ERROR: malformed ({e})")
    sys.exit(0)
print(settings.get("briefing", {}).get("provider", "(unset)"))
PYEOF
)
    print_check_line "settings.json" "ok" "briefing.provider=${PROVIDER_STATE}"
  else
    print_check_line "settings.json" "missing" "Run ./scripts/configure-provider.sh to choose Claude or Copilot."
    FAILURES=$((FAILURES + 1))
    PROVIDER_STATE=""
  fi

  if [[ -f "$ENV_FILE" ]] && grep -q '^GITHUB_TOKEN=' "$ENV_FILE"; then
    print_check_line "GITHUB_TOKEN" "ok" "Present in config/.env"
  else
    print_check_line "GITHUB_TOKEN" "missing" "Add GITHUB_TOKEN to config/.env."
    FAILURES=$((FAILURES + 1))
  fi

  if [[ -f "$ENV_FILE" ]] && grep -q '^GITHUB_USERNAME=' "$ENV_FILE"; then
    REPO_GITHUB_USERNAME=$(awk -F= '/^GITHUB_USERNAME=/{print $2; exit}' "$ENV_FILE")
    print_check_line "GITHUB_USERNAME" "ok" "$REPO_GITHUB_USERNAME"
  else
    print_check_line "GITHUB_USERNAME" "missing" "Run ./scripts/configure-github-account.sh."
    FAILURES=$((FAILURES + 1))
  fi

  if [[ -f "$ENV_FILE" ]] && grep -q '^GITHUB_ORG=' "$ENV_FILE"; then
    REPO_GITHUB_ORG=$(awk -F= '/^GITHUB_ORG=/{print $2; exit}' "$ENV_FILE")
    print_check_line "GITHUB_ORG" "ok" "$REPO_GITHUB_ORG"
  else
    print_check_line "GITHUB_ORG" "missing" "Run ./scripts/configure-github-account.sh."
    FAILURES=$((FAILURES + 1))
  fi

  if [[ "$PROVIDER_STATE" == "claude" ]]; then
    if [[ -f "$ENV_FILE" ]] && grep -q '^ANTHROPIC_API_KEY=' "$ENV_FILE"; then
      print_check_line "ANTHROPIC_API_KEY" "ok" "Present in config/.env"
    else
      print_check_line "ANTHROPIC_API_KEY" "missing" "Add ANTHROPIC_API_KEY for Claude mode."
      FAILURES=$((FAILURES + 1))
    fi
  elif [[ "$PROVIDER_STATE" == "copilot" ]]; then
    if command -v gh >/dev/null 2>&1; then
      print_check_line "gh" "ok" "$(gh --version | head -1)"
    else
      print_check_line "gh" "missing" "Install GitHub CLI for Copilot mode."
      FAILURES=$((FAILURES + 1))
    fi
  fi

  echo ""
  if [[ "$FAILURES" == "0" ]]; then
    echo "${GREEN}✓ Setup check passed${RESET}"
    exit 0
  fi

  echo "${YELLOW}Setup check found ${FAILURES} issue(s).${RESET}"
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required." >&2
  exit 1
fi

if ! command -v pip3 >/dev/null 2>&1; then
  echo "ERROR: pip3 is required." >&2
  exit 1
fi

echo ""
echo "${BOLD}— ritual first run —${RESET}"
echo ""

echo "${DIM}Installing Python dependencies...${RESET}"
pip3 install google-auth-oauthlib google-auth-httplib2 google-api-python-client python-dotenv requests

mkdir -p "$CONFIG_DIR" "$ROOT_DIR/notes"

if [[ -f "$ENV_FILE" ]]; then
  echo "${DIM}Keeping existing config/.env${RESET}"
else
  cp "$ENV_EXAMPLE" "$ENV_FILE"
  echo "${GREEN}✓ Created config/.env from template${RESET}"
fi

if [[ -f "$CONFIG_DIR/oneone-map.zsh" ]]; then
  echo "${DIM}Keeping existing config/oneone-map.zsh${RESET}"
else
  cp "$CONFIG_DIR/oneone-map.zsh.example" "$CONFIG_DIR/oneone-map.zsh"
  echo "${GREEN}✓ Created config/oneone-map.zsh from template${RESET}"
fi

  chmod +x \
    "$SCRIPT_DIR/start-workday.sh" \
    "$SCRIPT_DIR/end-workday.sh" \
    "$SCRIPT_DIR/configure-provider.sh" \
    "$SCRIPT_DIR/configure-github-account.sh" \
    "$SCRIPT_DIR/first-run.sh"

echo "${GREEN}✓ Scripts are executable${RESET}"

"$CONFIGURE_GITHUB_ACCOUNT_SCRIPT"

# Re-source .env so values written by configure-github-account.sh are live in this session
if [[ -f "$CONFIG_DIR/.env" ]]; then
  set -a
  source "$CONFIG_DIR/.env"
  set +a
fi

if [[ -n "$PROVIDER_ARG" ]]; then
  "$CONFIGURE_PROVIDER_SCRIPT" "$PROVIDER_ARG"
else
  "$CONFIGURE_PROVIDER_SCRIPT"
fi

echo "${BOLD}Next steps:${RESET}"
echo "1. Review config/.env and paste a fine-grained PAT for the selected GitHub account."
echo "2. If you chose Claude, add ANTHROPIC_API_KEY to config/.env."
echo "3. If you chose Copilot, run: gh copilot"
echo "4. Add config/credentials.json and run: python3 scripts/fetch-calendar.py"
echo "5. Update config/oneone-map.zsh with your exact 1:1 calendar titles"
echo ""
