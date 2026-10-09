"""Static NBA feed service for Render.

The maintainer's Mac builds JSON files in ``data``. Render deploys those files
with this API, so the service never needs to scrape NBA sources at request time.
"""

from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query


ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
app = FastAPI(title="Shattered Backboard NBA Data", version="2.0")


@lru_cache(maxsize=16)
def load_json(name: str, default_json: str | None = None):
    default = json.loads(default_json) if default_json is not None else None
    path = DATA / name
    if not path.exists():
        if default is not None:
            return default
        raise HTTPException(status_code=404, detail=f"Feed {name} is not available")
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise HTTPException(status_code=503, detail=f"Feed {name} could not be loaded") from error


@app.get("/")
def index():
    manifest = load_json("manifest.json", "{}")
    return {
        "status": "ok",
        "service": "Shattered Backboard NBA Data",
        "season": manifest.get("season"),
        "generated_at": manifest.get("generated_at"),
    }


@app.get("/health")
def health():
    return {"status": "ok", "manifest": (DATA / "manifest.json").exists()}


@app.get("/nba/manifest")
def manifest():
    return load_json("manifest.json", "{}")


@app.get("/nba/schedule")
def schedule(date: str | None = Query(default=None)):
    payload = load_json("schedule.json", '{"games": []}')
    games = payload.get("games") or []
    if date:
        games = [game for game in games if str(game.get("date") or payload.get("date") or "") == date]
    return {**payload, "date": date or payload.get("date"), "games": games}


@app.get("/nba/standings")
def standings():
    return load_json("standings.json", '{"standings": []}')


@app.get("/nba/stats")
def stats():
    return load_json("stats.json", '{"players": []}')


@app.get("/nba/roster")
def roster():
    return load_json("roster.json", '{"players": []}')


@app.get("/nba/lineups")
def lineups():
    return load_json("lineups.json", '{"rows": []}')


@app.get("/nba/team_advanced")
def team_advanced():
    return load_json("team_advanced.json", '{"teams": []}')


@app.get("/nba/team_position_splits")
def team_position_splits():
    return load_json("team_position_splits.json", '{"splits": []}')


@app.get("/nba/player_advanced")
def player_advanced():
    return load_json("player_advanced.json", '{"players": []}')


@app.get("/nba/player_logs")
def player_logs(
    player_id: str = Query(min_length=1, max_length=80),
    season: int | None = Query(default=None, ge=1947, le=2200),
    days: int = Query(default=90, ge=1, le=365),
    start_date: str | None = Query(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$"),
):
    payload = load_json("player_logs.json", '{"logs_by_player": {}}')
    logs = list((payload.get("logs_by_player") or {}).get(str(player_id), []))
    if season is not None:
        logs = [row for row in logs if int(row.get("season") or season) == season]
    if start_date:
        logs = [row for row in logs if str(row.get("game_date") or "") >= start_date]
    logs.sort(key=lambda row: str(row.get("game_date") or ""), reverse=True)
    return {"player_id": player_id, "season": season or payload.get("season"), "logs": logs[:days]}


@app.get("/nba/player_logs_bulk")
def player_logs_bulk(
    player_ids: str = Query(min_length=1, max_length=4_000),
    season: int | None = Query(default=None, ge=1947, le=2200),
    days: int = Query(default=90, ge=1, le=365),
):
    payload = load_json("player_logs.json", '{"logs_by_player": {}}')
    source = payload.get("logs_by_player") or {}
    requested = [value.strip() for value in player_ids.split(",") if value.strip()]
    result = {}
    for player_id in requested:
        rows = list(source.get(player_id, []))
        if season is not None:
            rows = [row for row in rows if int(row.get("season") or season) == season]
        rows.sort(key=lambda row: str(row.get("game_date") or ""), reverse=True)
        result[player_id] = rows[:days]
    return {"season": season or payload.get("season"), "logs_by_player": result}
