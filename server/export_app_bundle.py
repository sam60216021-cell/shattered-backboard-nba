#!/usr/bin/env python3
"""Export the checked-in server archive as the iOS app's offline seed data."""

from __future__ import annotations

import argparse
import json
from datetime import datetime, timezone
from pathlib import Path


ROOT = Path(__file__).resolve().parent
DEFAULT_DATA = ROOT / "data"
DEFAULT_OUTPUT = ROOT.parent / "Shattered Backboard NBA Stats" / "StarterLogs.json"
LOG_FIELDS = (
    "season", "player_id", "game_date", "team", "opponent", "mp_seconds",
    "pts", "reb", "ast", "three_p", "ftm", "fga", "fta", "stl", "blk", "tov",
)


def read_json(path: Path, default: dict) -> dict:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return default


def write_json_atomic(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(
        json.dumps(payload, separators=(",", ":"), sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def export_bundle(data_dir: Path, output: Path) -> tuple[int, int]:
    log_payload = read_json(data_dir / "player_logs.json", {"logs_by_player": {}})
    roster = read_json(data_dir / "roster.json", {"players": []})
    schedule = read_json(data_dir / "schedule.json", {"games": []})

    flattened: list[dict] = []
    for player_id, rows in (log_payload.get("logs_by_player") or {}).items():
        for raw in rows or []:
            row = {key: raw.get(key) for key in LOG_FIELDS if raw.get(key) is not None}
            row["player_id"] = str(row.get("player_id") or player_id)
            if row.get("game_date"):
                flattened.append(row)

    unique = {
        (str(row["player_id"]), str(row["game_date"])): row
        for row in flattened
    }
    logs = sorted(
        unique.values(),
        key=lambda row: (str(row["player_id"]), str(row["game_date"])),
    )
    players = roster.get("players") or []
    games = schedule.get("games") or []
    if len(logs) < 1_000:
        raise RuntimeError(f"Refusing to export an incomplete archive with only {len(logs)} logs")
    if len(players) < 300:
        raise RuntimeError(f"Refusing to export an incomplete roster with only {len(players)} players")

    seasons = sorted({int(row.get("season") or 0) for row in logs if row.get("season")})
    generated_at = datetime.now(timezone.utc).isoformat()
    payload = {
        "season": int(log_payload.get("season") or (seasons[-1] if seasons else 0)),
        "generated_at": generated_at,
        "note": f"Offline server archive: {len(logs)} logs for {len(players)} roster players.",
        "players": players,
        "games": games,
        "logs": logs,
    }
    write_json_atomic(output, payload)
    return len(logs), len(players)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--data", type=Path, default=DEFAULT_DATA)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()
    logs, players = export_bundle(args.data, args.output)
    print(f"Exported {logs} logs and {players} players to {args.output}")


if __name__ == "__main__":
    main()
