# Shattered Backboard NBA server

This directory follows the same deployment model as GridPicks:

1. Double-click the `NBA Publish.command` desktop shortcut on the Mac.
2. `update_server.py` downloads the upcoming schedule, all 30 active rosters,
   current standings, and the last seven days of completed ESPN box scores.
   It merges and deduplicates player game logs, rebuilds current-season player
   averages and advanced usage, and downloads projected or confirmed starting
   lineups from RotoWire.
3. The updater validates the responses and atomically saves them in
   `server/data`. Incomplete rosters and mismatched lineup slates are rejected.
4. The same run exports the complete checked-in player-log archive, roster, and
   schedule into the iOS app's `StarterLogs.json`. Every subsequent app build
   therefore contains a permanent offline baseline and only needs incremental syncs.
5. The launcher commits the server updater, generated feeds, and app archive, pushes `main`
   to GitHub, and Render deploys them automatically. Render does not scrape
   third-party sites during feed requests. AI chat separately performs bounded
   research only when requested and configured.

`build_feeds.py` remains available for importing historical game logs and
advanced feeds from an older local dataset, but routine publishing no longer
depends on the deleted `~/Documents/sports/nba-server` directory.

Use `server/render.yaml` as the Blueprint path. It explicitly sets `rootDir:
server`, declares both provider secrets and the private chat access token, and
uses the **Free** plan with temporary local budget accounting. No persistent disk
or paid service is required. No credentials belong in this repo.

For the existing service, keep `OPENAI_API_KEY` and `NBA_CHAT_TOKEN` in Render's
Environment settings. Native web research uses the same OpenAI key; no separate
search credential is required. Render does
not prompt for newly added `sync: false` secrets when updating an existing
Blueprint. Choose a long random value for `NBA_CHAT_TOKEN` and enter that same
value in the app's Chat Settings; it is separate from the OpenAI key.

If the service was created manually, updating YAML alone does not apply its
settings. Keep Root Directory `server`, instance type Free, and
`NBA_CHAT_DAILY_USD=2`. The old `NBA_CHAT_LEDGER` variable is ignored and may be
removed. Use the build and start commands in the Blueprint. Temporary accounting
and duplicate protection reset on restart/redeploy/spin-down. Request budgets
are estimates, not guaranteed billing caps; monitor OpenAI spending manually.
Deploy the commit containing `app.py`, `chat_api.py`, and the chat tests together.
The build now runs the offline regression suite, including route registration.

After deployment, run `python3 server/check_chat_deployment.py` from the repo,
then use Chat Settings → Check server and model access. See [CHAT_SETUP.md](CHAT_SETUP.md)
for secret setup and an inexpensive end-to-end check. The existing Render URL
can stay unchanged when updating the same service.

For manual Web Service setup, use this start command:

```text
uvicorn app:app --host 0.0.0.0 --port $PORT --workers 1 --no-access-log
```
