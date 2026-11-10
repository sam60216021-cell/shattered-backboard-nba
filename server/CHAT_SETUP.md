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

- Server default and maximum analysis budget: $0.25. Lower client-selected budgets remain respected.
- Default model: `gpt-6-luna`; optional `gpt-6.1-sol`; no silent upgrade/fallback.
- Luna server input defaults: 24,000 per call and 100,000 cumulative per analysis.
  `NBA_CHAT_MAX_INPUT_PER_CALL` accepts integers 2,000–64,000;
  `NBA_CHAT_MAX_INPUT_TOTAL` accepts integers 2,000–1,000,000. Invalid values fail
  before provider calls. Client `max_input` may be null (server default) or a
  smaller explicit cap. The server cap always wins. Sol retains a 16,000 per-call
  ceiling. Luna's maximum configured 64,000 input + 50,000 output is well inside
  its documented 1,050,000 context window and below long-input pricing thresholds.
- At most six model calls, six application tools, three web searches (default two).
- Up to 160 eligible player records reach the private gateway; only up to 24
  summaries initially reach OpenAI. Token preflight reduces initial detail if
  needed. Omitted players remain in the directory for targeted retrieval.
- Each database tool returns at most four players and ten logs per player.
- Raw missing values stay null. The existing engine's predictions remain intact.
- Luna: `max_output_tokens=50000` on every admitted Responses API call, including
  reasoning. No smaller aggregate output cap overrides Luna. Other model limits
  remain 2,500/call and 8,000 aggregate. The 16,000 limit is input-only.
- Cost admission reserves the full output allowance; it refuses a call if the
  remaining budget cannot cover it, rather than silently reducing output tokens.
  Six-call and input limits still apply. A 90-second provider timeout and the
  client's 600-second timeout can stop long analyses. There are no automatic retries.
- Sanitized response logs report status, interruption reason, input/output/reasoning
  usage and estimated cost. Unknown consumption after a timeout is logged as unknown
  with a cost reservation, never as measured usage. Incomplete predictions are withheld.
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

## November 10 analysis diagnostics

The 50,000 output allowance was local and uncommitted at investigation time;
the last published commit 4518223 still had 2,500/call and 8,000 aggregate.
Do not infer a live deployment's output allowance from the app UI or billing totals.

A mocked broad analysis reproduced three completed tool responses, 36,000 input
tokens and only 300 output tokens, followed by a blocked fourth call at the
40,000 aggregate input gate. This reproduces the symptom, not proof of the
production incident. The backend now requests a conclusion with tools disabled
when another similarly sized round would exceed that ceiling; it recounts the
changed request before admission. All existing spending/token gates still apply.
This may yield fewer supported legs when verification is incomplete.

Each analysis returns a trace_id, stop_reason, and numeric/allowlisted diagnostics.
Logs correlate start, admission, generation_start, provider_response, usage,
tool_result, finalization, and finish. They omit prompts, queries, player records,
credentials and raw errors. A generation_start without a matching response/finish
requires Render events/logs to distinguish process termination from a hanging
request. Aggregate OpenAI billing cannot establish the cause of one failure.

Completed tool responses continue with function_call_output and reasoning items.
A completed response without text/tools is now explicitly empty_response, not
success. Input limits, spending blocks, preflight errors, timeouts, and OpenAI
incomplete reasons are distinct. Only actual max_output_tokens reasons are
reported as provider output/context exhaustion, with reported consumption.

For a failing live request, retain the diagnostic reference and matching nba.chat
log events plus the Render deploy/restart events and HTTP status. Do not share
keys, tokens, or private conversations. No expensive live test is needed for
local validation. Sportsbook lines must be verified before actionable picks;
otherwise the assistant must clearly abstain or offer conditional analysis.

## Confirmed per-call input failure and research checks

`count > per_call_limit` is the per-Responses-call preflight gate;
`input_total + count > total_input_limit` is the distinct cumulative gate.
The reported 17,923 next input exceeded the old 12,000 default/16,000 maximum,
regardless of the $0.25 budget or 50,000 output allowance. A regression test now
passes 13,000 + 13,397 + 17,923 input tokens (44,320 cumulative) through continuation.

Rebuild the iOS app to get the new Server default input setting. The separate
V2 preference prevents an old saved 8,000–16,000 setting silently overriding the
new server default. Old app builds still send their explicit low limit; those
limits are deliberately honored. Existing budget preferences are unchanged.
Manual Render services use the code defaults without adding variables; the YAML
also declares the defaults for Blueprints. No disk or new service is required.

Research remains a supported Responses function call named research, executed by
this backend through Brave; it is not OpenAI's hosted web_search tool. Keep
BRAVE_SEARCH_API_KEY on Render. The web toggle and max_searches arrive from iOS;
they do not establish credentials or prove a search executed. Logs distinguish
missing_brave_key, research_provider_error, research_timeout, no_sources,
research_budget, web_disabled, search_limit and cached_research. Searches counts
attempted external searches; successful_searches counts responses with sources.
Neither count proves that evidence is relevant or that current odds are verified.
Absent evidence produces an explicit disclaimer, never invented lines.

Repeated player retrievals return references to earlier full records; repeated
identical queries reuse earlier evidence without another external search or
copying its excerpts again. Stateless model calls still carry the necessary
conversation history; it cannot simply be discarded without losing evidence.
All player projections, injury/matchup context and underlying calculations stay
unchanged. Research reserves its configured charge plus room for a subsequent
model call before execution. Dollar admission remains estimated, not a guaranteed
provider invoice cap; ephemeral daily accounting resets as described above.
