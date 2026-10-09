# Shattered Backboard NBA server

This directory follows the same deployment model as GridPicks:

1. Run `NBA Publish.command` on the Mac.
2. The existing local NBA updater refreshes its source files.
3. `build_feeds.py` packages portable feeds into `server/data`, including a
   freshness manifest and estimated player usage metrics.
4. Commit and push the repository. Render deploys `app.py` and serves only the
   generated JSON; it does not scrape third-party sites during app requests.

Create the Render service from `server/render.yaml` with `server` as the root
directory. After deployment, set `SportConfig.baseURL` in the iOS app to the
Render HTTPS URL.

