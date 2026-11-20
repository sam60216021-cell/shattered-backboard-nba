#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
REPO_DIR="${SCRIPT_DIR:h}"

STAGE="starting"
finish() {
    local result=$?
    if (( result != 0 )); then
        print -u2 ""
        print -u2 "NBA updater stopped while $STAGE (exit code $result)."
        print -u2 "The error above explains the failure. No automatic retry was made."
    fi
    if [[ -t 0 ]]; then
        print ""
        read -k1 "?Press any key to close." || true
    fi
    return $result
}
trap finish EXIT

cd "$REPO_DIR"
STAGE="refreshing NBA feeds"
print "Refreshing NBA feeds. Historical game downloads can take a few minutes."
python3 -u "$SCRIPT_DIR/update_server.py"

STAGE="staging refreshed files"
git add server "Shattered Backboard NBA Stats/StarterLogs.json"

if git diff --cached --quiet; then
    echo ""
    echo "NBA feeds are already current. Nothing to publish."
else
    STAMP="$(date '+%Y-%m-%d %H:%M %Z')"
    STAGE="committing refreshed files"
    git commit -m "Update NBA server feeds ($STAMP)"
    STAGE="pushing to GitHub"
    git push origin main
    echo ""
    echo "Updated NBA feeds and the app's offline archive were pushed to GitHub."
    echo "Render will deploy them automatically."
fi

