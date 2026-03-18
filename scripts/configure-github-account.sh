#!/usr/bin/env zsh
# configure-github-account.sh
# Configure the repo-local GitHub account values used by fetch-github.py.
#
# Usage:
#   ./scripts/configure-github-account.sh
#   ./scripts/configure-github-account.sh --username your-username --org your-org --project-number your-project-number

set -euo pipefail

SCRIPT_DIR="${0:A:h}"
ROOT_DIR="${SCRIPT_DIR:h}"
CONFIG_DIR="$ROOT_DIR/config"
ENV_FILE="$CONFIG_DIR/.env"
ENV_EXAMPLE="$CONFIG_DIR/.env.example"

BOLD='\033[1m'
RESET='\033[0m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'

usage() {
  cat <<'EOF'
Usage: scripts/configure-github-account.sh [--username USERNAME] [--org ORG] [--project-number NUMBER]

Updates the repo-local config/.env GitHub settings for this repository only.
EOF
}

USERNAME=""
ORG=""
PROJECT_NUMBER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --username)
      USERNAME="${2:-}"
      shift 2
      ;;
    --org)
      ORG="${2:-}"
      shift 2
      ;;
    --project-number)
      PROJECT_NUMBER="${2:-}"
      shift 2
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
done

mkdir -p "$CONFIG_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  cp "$ENV_EXAMPLE" "$ENV_FILE"
fi

read -r CURRENT_USERNAME CURRENT_ORG CURRENT_PROJECT <<EOF
$(python3 - "$ENV_FILE" <<'PYEOF'
from pathlib import Path
import sys

values = {}
for line in Path(sys.argv[1]).read_text().splitlines():
    if "=" in line and not line.lstrip().startswith("#"):
        key, value = line.split("=", 1)
        values[key] = value

print(values.get("GITHUB_USERNAME", ""))
print(values.get("GITHUB_ORG", ""))
print(values.get("GITHUB_PROJECT_NUMBER", ""))
PYEOF
)
EOF

if [[ -z "$USERNAME" ]]; then
  printf "GitHub username for this repo [%s]: " "${CURRENT_USERNAME:-}"
  read -r USERNAME
  USERNAME="${USERNAME:-$CURRENT_USERNAME}"
fi

if [[ -z "$ORG" ]]; then
  printf "GitHub org for this repo [%s]: " "${CURRENT_ORG:-}"
  read -r ORG
  ORG="${ORG:-$CURRENT_ORG}"
fi

if [[ -z "$PROJECT_NUMBER" ]]; then
  printf "GitHub project number for this repo [%s]: " "${CURRENT_PROJECT:-}"
  read -r PROJECT_NUMBER
  PROJECT_NUMBER="${PROJECT_NUMBER:-$CURRENT_PROJECT}"
fi

if [[ -z "$USERNAME" || -z "$ORG" ]]; then
  echo "ERROR: GitHub username and org are required." >&2
  exit 1
fi

python3 - "$ENV_FILE" "$USERNAME" "$ORG" "$PROJECT_NUMBER" <<'PYEOF'
from pathlib import Path
import sys

env_path = Path(sys.argv[1])
new_username = sys.argv[2]
new_org = sys.argv[3]
new_project = sys.argv[4]

lines = env_path.read_text().splitlines()
entries = []
values = {}

for line in lines:
    if "=" in line and not line.lstrip().startswith("#"):
        key, value = line.split("=", 1)
        values[key] = value
        entries.append((key, value))
    else:
        entries.append((None, line))

values["GITHUB_USERNAME"] = new_username
values["GITHUB_ORG"] = new_org
values["GITHUB_PROJECT_NUMBER"] = new_project

written = set()
output = []
for key, payload in entries:
    if key is None:
      output.append(payload)
      continue
    if key in {"GITHUB_USERNAME", "GITHUB_ORG", "GITHUB_PROJECT_NUMBER"}:
      if key not in written:
          output.append(f"{key}={values.get(key, '')}")
          written.add(key)
    else:
      output.append(f"{key}={payload}")

for key in ["GITHUB_ORG", "GITHUB_PROJECT_NUMBER", "GITHUB_USERNAME"]:
    if key not in written and key in values:
        output.append(f"{key}={values.get(key, '')}")

env_path.write_text("\n".join(output) + "\n")
PYEOF

echo ""
echo "${GREEN}✓ Updated repo-local GitHub settings${RESET}"
echo "${DIM}config/.env now targets ${USERNAME} in ${ORG}${RESET}"
echo ""

echo ""
echo "Required PAT permissions:"
echo "- Issues: Read"
echo "- Pull requests: Read"
echo "- Projects: Read"
echo ""
