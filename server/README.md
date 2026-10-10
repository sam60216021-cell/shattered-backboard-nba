# Shattered Backboard NBA server

This directory follows the same deployment model as GridPicks:

1. Double-click the `NBA Publish.command` desktop shortcut on the Mac.
2. `update_server.py` downloads the upcoming schedule and all 30 active
   rosters from ESPN, plus projected or confirmed starting lineups from
   RotoWire.
3. The updater validates the responses and atomically saves them in
   `server/data`. Incomplete rosters and mismatched lineup slates are rejected.
4. The launcher commits only `server/data`, pushes `main` to GitHub, and Render
   deploys the static feeds automatically. Render does not scrape third-party
   sites during app requests.

`build_feeds.py` remains available for importing historical game logs and
advanced feeds from an older local dataset, but routine publishing no longer
depends on the deleted `~/Documents/sports/nba-server` directory.

Create the Render service from `server/render.yaml` with `server` as the root
directory. After deployment, set `SportConfig.baseURL` in the iOS app to the
Render HTTPS URL.

For manual Web Service setup, use this start command:

```text
uvicorn app:app --host 0.0.0.0 --port 10000
```
