#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
LEGACY_SERVER="$HOME/Documents/sports/nba-server"

if [[ -x "$LEGACY_SERVER/.venv/bin/python3" ]]; then
    PYTHON="$LEGACY_SERVER/.venv/bin/python3"
else
    PYTHON="python3"
fi

if [[ -f "$LEGACY_SERVER/update.py" ]]; then
    "$PYTHON" "$LEGACY_SERVER/update.py"
fi

python3 "$SCRIPT_DIR/build_feeds.py" --source "$LEGACY_SERVER/data/nba"

echo ""
echo "NBA feeds are ready in $SCRIPT_DIR/data"
echo "Commit and push this project to trigger the Render deployment."
read -k1 "?Press any key to close."

