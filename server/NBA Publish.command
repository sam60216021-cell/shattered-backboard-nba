#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_DIR="${SCRIPT_DIR:h}"

cd "$REPO_DIR"
python3 "$SCRIPT_DIR/update_server.py"

git add server "Shattered Backboard NBA Stats/StarterLogs.json"

if git diff --cached --quiet; then
    echo ""
    echo "NBA feeds are already current. Nothing to publish."
else
    STAMP="$(date '+%Y-%m-%d %H:%M %Z')"
    git commit -m "Update NBA server feeds ($STAMP)"
    git push origin main
    echo ""
    echo "Updated NBA feeds and the app's offline archive were pushed to GitHub."
    echo "Render will deploy them automatically."
fi

echo ""
read -k1 "?Press any key to close."
