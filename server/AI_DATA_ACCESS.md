# NBA AI data access

## Root cause and changes

Previously `/nba/chat` saw only the iOS shortlist (up to 160 eligible players,
10 logs each; 24 initial summaries). `get_players` could only retrieve that same
upload. It could not read Render's archive or any app-only models, even though
those data already existed. Questionable/doubtful players were removed by the
chat adapter before analysis. The adapter now retains their status as evidence.
The original selection algorithms and weights are unchanged.

The new `query_nba_data` function batches up to four targeted queries. It uses
existing JSON feeds and content-addressed app snapshots, without putting the
whole database in the model prompt. History includes all stored seasons, with
date/season/opponent filtering, pagination and descriptive statistics over every
matching game. Null observations are excluded from those calculations, not
converted to zero. Fetch history first for independent analysis, then projections
for comparison. Conflicting app/server log fields are returned as
`app_differences`, preserving server observations rather than silently overwriting.
Exact-name identity aliases from the existing iOS store are exposed and used to
retrieve historical IDs; no new fuzzy identity guessing is introduced.

## Source inventory

| Data | Existing source/service | AI access and limitations |
| --- | --- | --- |
| Player identities and roster | Mac `update_server.py`, ESPN roster; SwiftData `StoredPlayer`; NBA commonallplayers / ESPN name hydration fallbacks | `players` searches the server and phone roster, including historical IDs and players outside today's slate. Provider identifiers/names are not independently verified by this change. |
| Game logs and minutes | ESPN completed box scores merged into `player_logs.json`; bundled `StarterLogs.json`; incremental `/nba/player_logs[_bulk]`; SwiftData `StoredGameLog` | `history` retrieves full stored records, shooting/defensive stats and minutes in seconds. Server keeps richer fields such as FGM, 3PA, plus-minus and game IDs. Phone export reads all retained local rows, not the ten-log shortlist. |
| Player season averages and usage | `stats.json`, `player_advanced.json`; local persisted advanced map | `player`; estimated possession usage remains labeled as an estimate, not official USG%. |
| Schedule, scores, game state | ESPN scoreboard -> schedule feed; app scoreboard fallback; `StoredGame`, `StoredGameDetails` | `matchup`; active and historical phone schedules/details supplement published server games. A published in-progress score may be stale; this is not a live score subscription. |
| Lineups and injury/availability labels | RotoWire lineup publisher; schedule missing-player fields; `StoredLineupPlayer`, `StoredMissingPlayer` | `matchup` returns existing feed and phone evidence with available timestamps. The `injuries` query also exposes ESPN roster injury statuses and report/check timestamps; an absent report does not confirm health. Optional native web research remains available. |
| Team records, points allowed | ESPN standings; `StoredStandings` | `team`, including app fallback values when present. |
| Team advanced defense and position splits | Optional `build_feeds.py` imports; `StoredTeamAdvanced`, `StoredTeamPositionSplit` | `team`; current published `team_advanced.json` and `team_position_splits.json` are absent. Existing cached phone values synchronize if present. Missing values remain unavailable. |
| Player-vs-player defense | `MatchupDefenseEvaluator` uses official/projected lineups, recent minutes, steals, blocks, rebounds | `projections` exports estimated defender, assignment confidence and activity. These are inferred assignments, not player-tracking observations. |
| Rotations | Recent minutes, projected starters, `SimulationEngine` top-rotation estimate | Minutes, lineups, projected minutes and game estimates are exposed. The `substitutions` query exposes observed substitution events by game ID. Full five-player stints are not reconstructed. |
| Play-by-play | Existing ESPN completed-game summaries retained by the publisher | `game_details` discovers historical game IDs, team box scores and observed starters; `play_by_play` pages events. Coverage is limited to collected games, not the entire historical archive. |
| Main statistical projections | `PredictionEngine.projectGame`, user category weights and calibration | `projections`: all 14 exported categories, confidence, ranges, minutes, decline/volatility. Values calculated by the unchanged Swift engine. Current calculations for finished games are explicitly not historical pregame forecasts. |
| Analytics / on-device AI / Blended numbers | `PredictionNumberEngine` | `projections`, separate values per category when enough history exists. |
| Prediction pipeline modules | `AnalyticsPredictionModule`, `OnDeviceAIPredictionModule`, `BlendedPredictionModule`, `PredictionPipeline.latestOutputs` | `projections.pipeline_outputs` includes existing latest run, model versions, reasoning and run time. Empty if that pipeline has not run on the phone; not silently manufactured. |
| Player and team Monte Carlo | `SimulationEngine` (used by player analytics and `ScheduleStore`) | Existing engine produces player quantiles and game score distributions/win probabilities for synchronized slate projections. Not a new server model. |
| Team baseline probabilities | `TeamProjection`, `OddsMath` | `matchup.app.team_projection`; model-implied probabilities, not sportsbook odds. |
| Graded projection history and backtests | `ProjectionTracker` JSON store; `LocalDataService.latestBacktestSummary` | `projections.tracked`, model-health bias/MAE, saved weights. Records outside a requested game are filtered. |
| App-generated player props | `StoredProp`, `ScheduleGame.playerProps` | Matchup snapshot; app-supplied and freshness unverified. No sportsbook verification requirement is added. |

## Structured endpoints and synchronization

All new endpoints require the existing `X-Chat-Token` / `NBA_CHAT_TOKEN`. Data-only
operations do not require or call OpenAI. No credential is uploaded in data records.

- `POST /nba/ai/sync/check`, body `{"records":{"player:2544":"<sha256>"}}`:
  returns missing content hashes and protocol 1. Checks happen before every chat.
- `POST /nba/ai/sync/records`, body `{"records":[{"digest":"<sha256>","body":"<JSON string>"}]}`:
  batches at most 20 changed records; hashes are checked against exact UTF-8 bytes.
  Single-record `/sync/record` is also available. Uploads are idempotent; after an
  interrupted sync, the next explicit send resumes only missing records.
- `POST /nba/ai/query`, body
  `{"records":{},"query":{"kind":"history","player_id":"2544","limit":20,"offset":0}}`.
  Kinds: `coverage`, `players`, `player`, `history`, `matchup`, `team`, `projections`.
  Optional filters: `search`, `team`, `opponent`, `game_id`, `start_date`, `end_date`,
  `season`. `next_offset` continues a page; the page size is not a history cutoff.

The iOS adapter exports records per player, game and team. Initial sync transfers
existing local history once; subsequent sends upload only records whose content
changed (record-level incremental sync, not individual-row deltas). Hash manifests
stay in backend context and are omitted from the OpenAI prompt. The model accesses
only requested records. No new SwiftData schema or feed-publisher rebuild is needed.

Snapshots use a disposable SQLite cache in the system temporary directory, with a
24-hour idle TTL and 64 MB content quota; no paid persistent disk. Referenced data
is checked before paid analysis; a restart between sync and chat returns a clear
409 `app_data_sync_required`, without an OpenAI call or automatic retry. Data-only
cache errors return 503. The existing chat cost ledger is separate and unchanged.
Snapshot access is scoped to hashes attached to that request, preventing accidental
use of another phone's last uploaded projection. Archives remain available without
phone sync. The phone remains necessary for current app-only model outputs.

## Validation (November 15, 2026)

- 63 offline backend tests pass: HTTP auth/schema/body limits, missing data, null
  preservation, date/season/opponent filters, pagination, incremental sync,
  duplicate uploads, restart recovery, app-only matchups, alias history, conflicting
  observations, batched model tool continuation, and existing cost/security tests.
- Actual checked-in archive queries: LeBron James (ID 2544), 79 historical games;
  Nikola Jokic (current ID 3112335), 11 games under that ID. More history under other
  IDs requires the phone's alias evidence or querying that historical ID.
- Actual IND–PHI game 401909985 resolves with one matching lineup row.
- Xcode build passes. Runtime export from the bundled-data environment produced
  716 snapshot records and 23,146 logs; full chat export produced 317 player/game
  projection sets across 14 categories. Largest record was 26,742 bytes. These
  are local measurements, not assertions about the connected phone's cache.
- Runtime Swift check confirms missing values encode as null and hashes have the
  expected 64-character SHA-256 representation.
- No paid OpenAI analysis was executed. Mock continuation verifies the retrieval
  path, not the quality of a live model's recommendations.

## Deployment

Deploy `ai_data.py`, updated `chat_api.py` / `app.py`, and both test suites together.
The Render build runs `test_*.py`. No new environment variables or paid services.
Existing clients still work and gain archive retrieval. Install the updated iOS
build to synchronize app-only history and projections; it requires these new
backend routes. The original $0.25 admission checks, 50,000 output allowance,
authentication, native web toggle and no-automatic-retry behavior are unchanged.
Cost estimates remain conservative estimates, not guaranteed provider billing caps.


## Game-level prediction clarification

The app does not use live sportsbook markets. AI exports now include both home
and away moneyline-style values directly from `TeamProjection.homeML/awayML` and
`GameSimulationResult.impliedHomeML/impliedAwayML`, alongside both win
probabilities, projected scores, spreads and totals. The exact existing
`ScheduleStore.simulations` cache is also synchronized as `schedule_simulation`,
separate from fresh calculations and the standings-based `team_projection`.
Positive spread means home favored/projected to outscore away; it is not an
invented sportsbook handicap. Player props remain existing app predictions.

Verification: Xcode runtime compared exported moneylines, probabilities, spreads
and totals to the unchanged engine for nine actual slate games; every value
matched exactly. The category integration check authenticates and queries every
major retrieval category, checks game/player models, props, injuries, lineups,
defense, history and model health, then verifies game predictions reach the next
model request through tool continuation. The suite now has 64 passing tests.
No sportsbook API or new prediction algorithm was added. Phone synchronization
is required for these app-only outputs; absent caches remain absent.


## Observed game data refresh (November 16, 2026)

The existing collector now retains normalized play-by-play, substitution events,
observed starters, team box-score totals, source URLs and retrieval timestamps in
`game_details.json`. It does not retain sportsbook fields or ESPN predictions.
These data are retrieved through the existing authenticated `/nba/ai/query`
endpoint and the model's `query_nba_data` tool. Event pages remain limited to 50
rows to avoid dumping entire games into context. No schema or algorithm changes.

`python3 server/update_server.py --lookback-days 30` backfills recent completed
games. Normal publishing refreshes seven days and merges retained older games.
The supported explicit backfill range is 1–60 days. Each refresh still fetches
recent summaries to pick up corrections; it never makes a paid OpenAI request.
Use the existing NBA Publish.command to refresh and publish subsequent updates;
Render serves the published snapshot, not an automatically updating live feed.

Lineup matching now uses only the current schedule date, preventing a later
repeat matchup from taking today's lineup. Historical logs use the scoreboard
slate date instead of the UTC tip-off date. ESPN roster injury reports are kept
with their original status/date, without interpreting absent reports as healthy.
Team box-score defensive observations are available; missing official defensive
ratings, position-defense splits and tracking assignments are not fabricated.
App-only projections still require phone synchronization.

## Repeatable connection audit

The publisher now writes `data_quality.json`, exposed to the AI through its
existing `coverage` query. Run `python3 server/audit_data.py` for a read-only
local report. It checks duplicate player/date rows, lineup/schedule joins,
history/game date and team joins, event/starter coverage, missing fields by
current season versus all history, unlinked roster IDs, and missing defensive
feeds. Issues and coverage limitations are reported without blocking predictions.

The November 19 audit found seven old UTC-date log mismatches. The publisher
now reconciles dates only when the exact game ID and both teams match the
archived game. It does not infer identity aliases, invent missing observations,
or change prediction weights. No errors in these checks is not evidence of
complete source coverage or improved forecast accuracy. Thirty-four roster IDs
had no direct history; no alternate identity was established in the collected
event participants. Phone-only identity aliases and model output availability
still depend on an up-to-date app sync.
