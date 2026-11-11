# NBA chat: Luna with native OpenAI web search

## Deployment and credentials

Keep the existing Render Free service, root directory `server`, and the build/start
commands in `render.yaml`. No paid disk, new service, or SDK upgrade is required.
The backend uses Python urllib to call `/v1/responses` directly. It does not use
Chat Completions or install the OpenAI SDK. Authentication remains `X-Chat-Token`.

| Variable | Purpose / default |
| --- | --- |
| OPENAI_API_KEY | Server-only credential for model analysis and native web search |
| NBA_CHAT_TOKEN | Private app access token; unchanged |
| NBA_CHAT_MAX_WEB_SEARCHES | 2; integer 0–3; bounds all native web actions, including page opens |
| NBA_CHAT_SEARCH_INPUT_RESERVE | 6,000; integer 2,000–16,000; estimated hosted-result input headroom per response |
| NBA_NATIVE_SEARCH_COST_USD | $0.01 per search action; finite $0.01–$0.05 |
| NBA_CHAT_DAILY_USD | Local daily estimated allowance, default $2 |

BRAVE_SEARCH_API_KEY and NBA_SEARCH_COST_USD are obsolete and ignored. They may be
removed from Render. New variable names prevent the old $0.005 search price from
underpricing OpenAI searches. Code defaults apply if the new variables are absent.
Manually created Render services need environment changes applied in the dashboard;
a YAML edit alone does not change their settings. Keep secrets out of source control.

The legacy client `max_input` field remains accepted for request compatibility but
no longer restricts generation. `NBA_CHAT_MAX_INPUT_PER_CALL` and
`NBA_CHAT_MAX_INPUT_TOTAL` are obsolete and ignored; remove them from Render if
present. No app rebuild or interface changes are required for this backend fix.
Client-selected budgets below $0.25 remain respected; requests above $0.25 fail
validation. A stopped client does not cancel server spending; do not blindly retry.

## Native research and evidence

Luna supports Responses `web_search`. Requests use `external_web_access: true`,
`search_context_size: low`, and `return_token_budget: default`; never unlimited.
The existing web toggle and max_searches are preserved. Web disabled, zero search
limit, or exhausted web-action allowance omits the tool entirely. Each admitted
response containing web search sets max_tool_calls=1. The analysis permits up to
the smaller of the app's limit and NBA_CHAT_MAX_WEB_SEARCHES. Page opens and finds
also consume that action allowance, making it conservative relative to searches.

OpenAI executes built-in tools internally. The backend still executes get_players
and returns function_call_output with prior reasoning/search output for continuation.
No automatic retry, provider fallback, or model switch occurs after a rejection.
Model/project access checked by `/nba/chat/status` does not prove native search
execution: native_search_access is not_tested until an actual reported execution.
The compatibility field research_configured now describes native-tool configuration,
not a separate search credential. Search is optional when available; the model
must not claim research when it did not run.

Instructions use database statistics and existing projections to generate picks
and conditional parlays even when web research is incomplete. Web research improves
recommendations but is not a prerequisite. Unverified availability/injuries must
be labeled; questionable or doubtful players require explicit participation/minutes
conditions and added risk. Known out/inactive/suspended players remain excluded.
Model-derived thresholds must be labeled as targets, never as actual sportsbook
offerings. Missing odds remain unavailable; no invented prices or payouts.
Unsupported statistical legs may still be omitted rather than fabricated.
Provider url_citation annotations become inline clickable links. Source records
include URLs and a UTC retrieved_at timestamp observed when the provider response
arrived (not the publication date). Retrieved sources alone do not independently
verify every claim, player status, or sportsbook offering. Sources from failed web
actions are excluded. A completed action without URLs is reported as unverified.

## Token and spending protection

- Luna remains gpt-6-luna, max_output_tokens=50000 including reasoning on each call.
- Input admission checks the actual model context: counted input plus configured
  output must fit 1,050,000 tokens. Luna retains 50,000 output tokens, leaving up to
  1,000,000 counted input tokens before the independent cost check. There is no
  arbitrary cumulative input cutoff; cumulative usage is still charged/tracked.
  Removed repeated shrinking/recounting and premature tool disabling based on the
  old 100,000 aggregate ceiling. Initial player summaries and targeted tools remain.
- Up to 160 catalog players, 24 initial summaries, four players/tool, ten logs/player.
  Predictions, database structure and statistical calculations are unchanged.
- Six model calls, six database tool calls maximum; native actions have their own
  smaller bound. No automatic retries or background resubmission.
- All request input is counted before generation. Native search result content is
  produced inside OpenAI and cannot be pre-counted exactly. Preflight admits the
  counted input against model context capacity and uses NBA_CHAT_SEARCH_INPUT_RESERVE
  only for cost estimation. It reserves estimated input, full output, one possible
  search fee, conservative cache-write
  pricing and a 10% margin before dispatch.
- The reserve and search_context_size are NOT hard limits on hosted result tokens.
  Actual reported input (including search content), output (including reasoning),
  and cache categories are reconciled once; search action fees are added separately.
  If reported usage exceeds model context capacity or budget, further calls stop and no final
  predictions from that over-limit response are presented. Charges can already
  have occurred. A timeout retains the whole reservation with unknown usage.
- Standard Luna prices: $0.10/M uncached input, $0.01/M cached input, $0.50/M output,
  $0.125/M 30-minute cache writes, $0.25/M 12-hour writes. Above 272,000 input
  tokens, input/cache rates double and output rates multiply by 1.5, in both cost
  preflight and actual usage accounting. Native search: $0.01/search
  action plus content tokens at model rates. Page opens/finds have no listed search
  action fee. Failed reported search actions are conservatively included in costs.
- **$0.25 is an enforced estimated admission ceiling, not a guaranteed invoice cap.**
  Provider pricing/usage behavior and unknown timeout charges can differ. Temporary
  SQLite duplicate/daily accounting resets on Render restarts, redeploys and idle
  spin-down. Monitor actual provider billing manually.

## Diagnostics and validation

Structured trace events report web_requested, native configuration/access state,
response status, per-call and cumulative usage, reasoning tokens, tool action/status,
model/search/total estimated costs, uncertain reservations, remaining budget and
exact stop reason. Logs exclude keys, headers, prompts, queries and source URLs.
`searches` counts completed search actions only; `web_actions` counts reported native
invocations. Requested/offered tools and timeouts without a response do not count
as completed searches. `successful_searches` means completed execution, not verified
odds. Separate model and web costs are returned with the existing response fields.

Run `python3 -m unittest discover -s server -p test_chat_api.py -v`. Tests mock
providers: no paid calls. Local startup uses the existing Render Uvicorn command.
Live project web-search access remains unverified until a real request executes.
For an optional inexpensive smoke test, select Luna, web enabled, one search, and
ask for one upcoming player's current injury status with a source. Inspect search
count, source URL/timestamp, trace and dashboard spending. Do not claim verified
sportsbook lines from an injury-only source.

Official references:
- https://developers.openai.com/api/docs/models/gpt-6-luna
- https://developers.openai.com/api/docs/guides/tools-web-search
- https://developers.openai.com/api/docs/pricing

## Default recommendation workflow

General picks/parlays are player/category recommendations based on the existing
database, projections and player-specific web research (form, minutes, roles,
injuries, availability and matchups). Sportsbook lookup and verification are not
part of the default workflow. Compare lines/odds only when the user provides them
or explicitly requests that comparison. Supplied lines are inputs, not independently
verified offerings. Explain strengths, realistic upside and risks; label unknown
player information without burying ordinary research in missing-odds disclaimers.

Completed answers are retained when the provider reports extra native web actions. All reported searches still count toward estimated spending. Pending database tools still execute after an unexpected web-action overrun, and the analysis continues without further web research, subject to the existing spending and context checks; no automatic retry occurs. Context and spending protections remain active.
