# Low-cost NBA chat setup

## Diagnosing the November 9 HTTP 404

Verified against the default live host: `POST /nba/chat` returned HTTP 404 with
`{"detail":"Not Found"}` while `/health` returned HTTP 200. Its `/openapi.json`
contained only feed routes, no chat route. This is an undeployed backend route,
not an OpenAI model failure or invalid sports data. Deploy **both** `app.py` and
`chat_api.py` from this workspace and configure the secrets below. The
old production deployment cannot be fixed by rebuilding only the iOS app.

After deploying, run `python3 server/check_chat_deployment.py` from the repository.
With `NBA_CHAT_TOKEN` privately set, it checks your project's model access using
`GET /v1/models/gpt-6-luna`; it never requests generation. The same check is in
AI Chat → Settings → Check server and model access. HTTP 200 verifies model
visibility and temporary accounting; actual generation permission still needs a smoke request.

For one inexpensive end-to-end request, select Luna, $0.05 budget and one search:
“Check one upcoming player's recent form, app projection, and latest injury
status. Use at most one web search. Explain one risk; do not build a parlay.”
Verify a dated source link and the usage/cost footer. No eligible games should
produce an explicit coverage explanation, never invented picks.

Client logs use category `PicksChat`; server logs use `nba.chat`. They record
stage, endpoint path, HTTP status, counts and allowlisted provider error codes.
They intentionally omit headers, raw error text, chat text and player records.

The app now calls `POST /nba/chat`; it never calls OpenAI directly. The existing
prediction algorithms and basketball database schema are unchanged.

## Required deployment

Deploy `app.py` and `chat_api.py` with the existing server requirements. Keep one
Uvicorn worker on the existing **Free** service. `server/render.yaml` specifies
`plan: free` and no disk. No paid service or new infrastructure is needed.
Temporary SQLite accounting uses the system temporary directory automatically.
`NBA_CHAT_LEDGER` is a legacy setting and is ignored, including old `/var/data`
values; it can be removed from Render Environment settings.

The Blueprint path is `server/render.yaml` and its root directory is `server`.
For an existing manually created service, keep its Free instance type and the
build/start commands in the YAML. A code push does not change dashboard settings.
Keep existing secrets unchanged. Existing services need any missing secret values
entered manually; `sync: false` does not prompt on existing Blueprint updates.

Set these in the hosting provider's secret/environment settings, never source:

| Variable | Purpose |
| --- | --- |
| `OPENAI_API_KEY` | OpenAI provider credential, server only |
| `NBA_CHAT_TOKEN` | A separate randomly generated private access token; enter this in Chat Settings |
| `BRAVE_SEARCH_API_KEY` | Bounded web research; absent means research explicitly unavailable |
| `NBA_CHAT_DAILY_USD` | Local rolling 24-hour estimated allowance; default `2` dollars; resets with storage; valid range >0 to 100 |
| `NBA_SEARCH_COST_USD` | Conservative per-search price for your Brave plan; default `0.005` dollars; must be finite, >0 and <=0.05; update if your plan changes |

Use HTTPS. Do not paste the OpenAI key into the app. On first launch the upgrade
selects Luna and removes the old device provider key. Add the separate access
token after configuring the server. This is a private-user gateway, not public
multi-user authentication; use proper user accounts before distributing access.

## Limits and accounting

- Default analysis budget: $0.10; configurable in the app.
- Default model: `gpt-6-luna`; optional `gpt-6.1-sol`; no silent upgrade/fallback.
- Default model input: 12,000 tokens/request, hard ceiling 16,000; 40,000 aggregate.
- At most six model calls, six application tools, three web searches (default two).
- Up to 160 eligible player records reach the private gateway; only up to 24
  summaries initially reach OpenAI. Token preflight reduces initial detail if
  needed. Omitted players remain in the directory for targeted retrieval.
- Each database tool returns at most four players and ten logs per player.
- Raw missing values stay null. The existing engine's predictions remain intact.
- 2,500 output tokens/call; 8,000 aggregate, including reasoning.
- All web results go through the next input-token check. No opaque hosted-search
  expansion occurs inside OpenAI requests. Research uses five dated search
  excerpts (including extra snippets), not full-page verification. Unresolved
  or conflicting evidence must remain explicitly unverified.
- Explicit-only caching without breakpoints avoids intentionally writing the
  changing sports data. Cost admission conservatively reserves at 2.5x input
  pricing plus an output allowance and 10% margin.
- Temporary local accounting atomically reserves the analysis allowance. Duplicate
  IDs return the saved result or report an unresolved run while that storage survives.
- Timeouts have no automatic retry; uncertain model costs retain their reserved
  allowance. A stopped client does not cancel server spending. Daily reservations
  are lost on restart, redeploy or idle spin-down. Duplicate protection also resets.
  Never automatically resend interrupted requests, including after restarting the app.
- Token counting is done before generation. Count-endpoint failures fail closed.
- Post-response usage records include token/cache breakdowns and response IDs,
  never provider keys or request headers. Model/search prices are estimates, not
  an invoice. Review prices before enabling and whenever providers change them.
- Budget accounting covers API usage, not hosting subscriptions or taxes. Search
  charges use your configured per-call rate, including uncertain failed calls.

## Budget limitations and 503 diagnostics

**$0.05 is an estimated request allowance, not a guaranteed provider billing cap.**
Prices, token accounting, uncertain timeouts and provider behavior can differ from
estimates. The local daily allowance is not an account-wide spending limit.
Monitor actual OpenAI spending manually. No dashboard alert is treated as a hard cap.
Render Free loses local files when it restarts or spins down:
https://render.com/docs/free#local-files-lost-on-redeploy

The former code returned 503 before any OpenAI call if `NBA_CHAT_LEDGER` was unset.
This was reproduced offline. The production 503's exact cause cannot be confirmed
from status alone without its authenticated error detail. A missing OpenAI key
also produced 503. The persistent-storage dependency has been removed.

Authenticated 503 responses now contain a sanitized `detail.code` and message:
- `missing_openai_key`: set the server-side key in Render; never in the client.
- `invalid_cost_settings`: correct the named cost setting; no provider call starts.
- `temporary_accounting_unavailable`: temporary SQLite cannot be accessed; fail
  safely without automatic retry. Previous work could already have been charged.

Provider failures remain distinguishable as 502 with sanitized provider/status
metadata. `/health` includes `chat_revision: free-storage-v2` and storage mode to
identify the deployment; it does not prove authenticated generation works.
The authenticated status check validates settings and writable temporary storage
before the no-generation model lookup. Logs never contain credentials or prompts.

## Validation

Run `python3 -m unittest discover -s server -p test_chat_api.py -v` from the repo.
The suite mocks providers and incurs no API charges. Build the iOS project in
Xcode. Live validation still requires deployment and server credentials.

For a first live run use Luna, a $0.05 budget and one search. Check the returned
usage against provider billing before increasing limits. Compare 3-leg and
6-leg requests, stale snapshots, injured players, missing history and follow-up
swaps. Require cited evidence and explicit abstention when support is lacking.
Typical researched requests are expected to cost cents, but this has not been
measured against the live service yet.
