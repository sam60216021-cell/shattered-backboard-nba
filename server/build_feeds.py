#!/usr/bin/env python3
"""Package locally generated NBA JSON into Render-ready static feeds."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent
DEFAULT_SOURCE = Path.home() / "Documents" / "sports" / "nba-server" / "data" / "nba"
PASSTHROUGH = ("schedule", "standings", "stats", "roster", "team_advanced", "team_position_splits")


def season_end_year(now: datetime) -> int:
    return now.year + 1 if now.month >= 10 else now.year


def read_json(path: Path, default):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def write_json(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def collect_logs(source: Path, season: int) -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = defaultdict(list)
    paths = sorted((source / "player_logs").glob("*.json"))

    # These files may live in an iCloud-backed Documents directory. Reading
    # them concurrently avoids turning a few hundred small files into a
    # several-minute serial export.
    with ThreadPoolExecutor(max_workers=16) as pool:
        payloads = pool.map(lambda path: (path, read_json(path, {})), paths)

        for path, payload in payloads:
            player_id = str(payload.get("player_id") or path.stem.split("_")[0])
            for row in payload.get("logs") or []:
                item = dict(row)
                item["player_id"] = str(item.get("player_id") or player_id)
                item["season"] = int(item.get("season") or season)
                grouped[player_id].append(item)
    for rows in grouped.values():
        unique = {(str(row.get("game_date")), str(row.get("player_id"))): row for row in rows}
        rows[:] = sorted(unique.values(), key=lambda row: str(row.get("game_date") or ""), reverse=True)
    return dict(grouped)


def build_player_advanced(logs_by_player: dict[str, list[dict]], roster: dict, stats: dict, season: int) -> dict:
    roster_by_id = {str(row.get("player_id")): row for row in stats.get("players") or []}
    roster_by_id.update({str(row.get("player_id")): row for row in roster.get("players") or []})
    team_game_possessions: dict[tuple[str, str], float] = defaultdict(float)
    for rows in logs_by_player.values():
        for row in rows:
            team = str(row.get("team") or "").upper()
            date = str(row.get("game_date") or "")
            possessions = float(row.get("fga") or 0) + 0.44 * float(row.get("fta") or 0) + float(row.get("tov") or 0)
            if team and date:
                team_game_possessions[(team, date)] += possessions

    players = []
    for player_id, rows in logs_by_player.items():
        valid = [row for row in rows if float(row.get("mp_seconds") or 0) > 0]
        if not valid:
            continue
        minutes = sum(float(row.get("mp_seconds") or 0) for row in valid) / 60.0
        possessions = sum(float(row.get("fga") or 0) + 0.44 * float(row.get("fta") or 0) + float(row.get("tov") or 0) for row in valid)
        shares = []
        for row in valid:
            team = str(row.get("team") or "").upper()
            date = str(row.get("game_date") or "")
            team_total = team_game_possessions.get((team, date), 0)
            player_total = float(row.get("fga") or 0) + 0.44 * float(row.get("fta") or 0) + float(row.get("tov") or 0)
            if team_total > 0:
                shares.append(player_total / team_total)
        info = roster_by_id.get(player_id, {})
        latest = valid[0]
        players.append({
            "player_id": player_id,
            "name": info.get("name") or latest.get("name") or player_id,
            "team": info.get("team") or latest.get("team"),
            "games": len(valid),
            "minutes_per_game": round(minutes / len(valid), 2),
            "estimated_usage_pct": round(100 * sum(shares) / len(shares), 2) if shares else None,
            "possessions_used_per_36": round(36 * possessions / minutes, 2) if minutes else None,
        })
    players.sort(key=lambda row: (row.get("team") or "", row.get("name") or ""))
    return {"season": season, "method": "FGA + 0.44*FTA + TOV share", "players": players}


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=ROOT / "data")
    args = parser.parse_args()
    generated_at = datetime.now(timezone.utc)
    season = season_end_year(generated_at)
    args.output.mkdir(parents=True, exist_ok=True)

    feeds = {}
    for name in PASSTHROUGH:
        source_path = args.source / f"{name}.json"
        if source_path.exists():
            destination = args.output / source_path.name
            shutil.copy2(source_path, destination)
            feeds[name] = destination

    lineup_candidates = sorted((args.source / "lineups").glob("*.json"))
    if lineup_candidates:
        destination = args.output / "lineups.json"
        shutil.copy2(lineup_candidates[-1], destination)
        feeds["lineups"] = destination

    logs_by_player = collect_logs(args.source, season)
    log_path = args.output / "player_logs.json"
    write_json(log_path, {"season": season, "logs_by_player": logs_by_player})
    feeds["player_logs"] = log_path

    roster = read_json(args.output / "roster.json", {"players": []})
    stats = read_json(args.output / "stats.json", {"players": []})
    advanced_path = args.output / "player_advanced.json"
    write_json(advanced_path, build_player_advanced(logs_by_player, roster, stats, season))
    feeds["player_advanced"] = advanced_path

    manifest_feeds = {}
    for name, path in feeds.items():
        body = path.read_bytes()
        manifest_feeds[name] = {"bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()}
    write_json(args.output / "manifest.json", {
        "schema_version": 2,
        "season": season,
        "generated_at": generated_at.isoformat(),
        "source": "local-nba-feed-builder",
        "feeds": manifest_feeds,
    })
    print(f"Built {len(feeds)} feeds for NBA season ending {season} in {args.output}")


if __name__ == "__main__":
    main()
