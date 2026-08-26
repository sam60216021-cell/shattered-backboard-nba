#!/usr/bin/env python3
"""
generate_starter_data.py
Fetches game logs for every player in today's lineups from the local server,
then writes StarterLogs.json into the app bundle source directory.

Usage (from the workspace root):
    python3 generate_starter_data.py

Requirements:
    pip install requests
"""

import json
import sys
import datetime
import requests

BASE_URL   = "http://192.168.0.7:8000"
SEASON     = 2026
DAYS       = 60
OUTPUT     = "Shattered Backboard NBA Stats/StarterLogs.json"


def fetch_json(path, params=None):
    url = BASE_URL + path
    try:
        r = requests.get(url, params=params, timeout=15)
        r.raise_for_status()
        return r.json()
    except Exception as e:
        print(f"  ERROR {path}: {e}", file=sys.stderr)
        return None


def main():
    print("Fetching roster for name→ID mapping…", file=sys.stderr)
    roster_data = fetch_json("/nba/roster")
    stats_data  = fetch_json("/nba/stats")

    # Build name → player_id from roster + stats (roster takes precedence)
    name_to_id: dict[str, str] = {}
    for p in (stats_data or {}).get("players", []):
        if p.get("name") and p.get("player_id"):
            name_to_id[p["name"]] = p["player_id"]
    for p in (roster_data or {}).get("players", []):
        if p.get("name") and p.get("player_id"):
            name_to_id[p["name"]] = p["player_id"]

    print(f"Roster map: {len(name_to_id)} players", file=sys.stderr)

    print("Fetching lineups…", file=sys.stderr)
    lineups_data = fetch_json("/nba/lineups")
    if not lineups_data:
        sys.exit("Could not reach server.")

    # Collect all player IDs from today's projected lineups (name → ID lookup).
    player_ids = {}   # id -> {"name": ..., "team": ...}
    for game in lineups_data.get("rows", []):
        for side in ("away_lineup", "home_lineup"):
            for p in game.get(side, []):
                name = p.get("name", "")
                pid  = p.get("player_id") or name_to_id.get(name)
                if pid:
                    player_ids[pid] = {"name": name, "team": p.get("team", "")}
                else:
                    print(f"  WARN no player_id for '{name}' — skipping", file=sys.stderr)

    # Also pull every player on the roster for today's scheduled teams,
    # so games without projected lineups (NYK@ATL, CLE@TOR, DEN@MIN, etc.)
    # still get log data for projections.
    print("Fetching schedule to find all today's teams…", file=sys.stderr)
    schedule_data = fetch_json("/nba/schedule")
    today_teams: set[str] = set()
    for game in (schedule_data or {}).get("games", []):
        if game.get("away"): today_teams.add(game["away"])
        if game.get("home"): today_teams.add(game["home"])
    print(f"Today's teams: {', '.join(sorted(today_teams))}", file=sys.stderr)

    # Build a team → [player_id] map from the full roster
    team_to_players: dict[str, list[dict]] = {}
    for p in (roster_data or {}).get("players", []):
        pid  = p.get("player_id")
        team = p.get("team", "")
        name = p.get("name", "")
        if pid and team and name:
            team_to_players.setdefault(team, []).append({"player_id": pid, "name": name, "team": team})

    for team in today_teams:
        for p in team_to_players.get(team, []):
            pid = p["player_id"]
            if pid not in player_ids:
                player_ids[pid] = {"name": p["name"], "team": team}

    if not player_ids:
        sys.exit("No players found in lineups or schedule response.")

    print(f"Found {len(player_ids)} players — fetching logs…", file=sys.stderr)

    all_logs = []
    for pid, meta in player_ids.items():
        data = fetch_json("/nba/player_logs", params={
            "player_id": pid,
            "season": SEASON,
            "days": DAYS,
        })
        if data:
            logs = data.get("logs") or []
            all_logs.extend(logs)
            print(f"  ✓ {meta['name']} ({meta['team']}): {len(logs)} logs", file=sys.stderr)
        else:
            print(f"  ✗ {pid}: no data", file=sys.stderr)

    output = {
        "season": SEASON,
        "note": f"Generated {datetime.date.today().isoformat()} — {len(all_logs)} log rows for {len(player_ids)} players.",
        "logs": all_logs,
    }

    with open(OUTPUT, "w") as f:
        json.dump(output, f, indent=2)

    print(f"\nWrote {len(all_logs)} log entries to {OUTPUT}", file=sys.stderr)


if __name__ == "__main__":
    main()
