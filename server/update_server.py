#!/usr/bin/env python3
"""Refresh the checked-in NBA feeds used by the Render service.

The Mac is the collector: ESPN supplies the schedule and full active rosters,
while RotoWire supplies projected/confirmed starting lineups. Validated JSON is
written atomically into ``server/data`` before Git deploys it to Render.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import re
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) ShatteredBackboard/1.0"
TEAM_ALIASES = {"GS": "GSW", "NY": "NYK", "NO": "NOP", "SA": "SAS", "UTAH": "UTA", "WSH": "WAS"}


def fetch_json(url: str) -> dict:
    request = Request(url, headers={"User-Agent": USER_AGENT, "Accept": "application/json"})
    with urlopen(request, timeout=30) as response:
        return json.load(response)


def fetch_text(url: str) -> str:
    request = Request(url, headers={"User-Agent": USER_AGENT, "Accept": "text/html"})
    with urlopen(request, timeout=30) as response:
        return response.read().decode("utf-8", "ignore")


def write_json(path: Path, payload: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    temporary.replace(path)


def normalize_team(value: str | None) -> str:
    abbr = str(value or "").strip().upper()
    return TEAM_ALIASES.get(abbr, abbr)


def normalized_name(value: str | None) -> str:
    value = html.unescape(str(value or "")).lower()
    value = value.replace("’", "'").replace(".", "").replace("'", "")
    return re.sub(r"[^a-z0-9]+", " ", value).strip()


def load_existing_players(output: Path) -> dict[str, dict]:
    players: dict[str, dict] = {}
    for filename in ("stats.json", "roster.json"):
        try:
            payload = json.loads((output / filename).read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        for row in payload.get("players") or []:
            name = normalized_name(row.get("name"))
            if name and row.get("player_id"):
                players[name] = row
    return players


def refresh_roster(output: Path, generated_at: str) -> dict:
    teams_payload = fetch_json("https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams")
    teams = (((teams_payload.get("sports") or [{}])[0].get("leagues") or [{}])[0].get("teams") or [])
    team_codes = sorted({
        (
            str(item.get("team", {}).get("abbreviation") or "").strip(),
            normalize_team(item.get("team", {}).get("abbreviation")),
        )
        for item in teams
        if normalize_team(item.get("team", {}).get("abbreviation"))
    })
    if len(team_codes) != 30:
        raise RuntimeError(f"ESPN team list validation failed: expected 30, received {len(team_codes)}")

    existing = load_existing_players(output)

    def fetch_team(route_code: str, team: str) -> tuple[str, list[dict]]:
        url = f"https://site.api.espn.com/apis/site/v2/sports/basketball/nba/teams/{route_code.lower()}/roster"
        payload = fetch_json(url)
        return team, payload.get("athletes") or []

    players: list[dict] = []
    with ThreadPoolExecutor(max_workers=10) as pool:
        futures = [pool.submit(fetch_team, route_code, team) for route_code, team in team_codes]
        for future in as_completed(futures):
            team, athletes = future.result()
            for athlete in athletes:
                name = athlete.get("fullName") or athlete.get("displayName")
                if not name:
                    continue
                prior = existing.get(normalized_name(name), {})
                position = athlete.get("position", {}).get("abbreviation") or prior.get("pos")
                # Preserve the NBA/stat-feed ID when names match so player logs remain linked.
                player_id = str(prior.get("player_id") or athlete.get("id") or "")
                if player_id:
                    players.append({"player_id": player_id, "name": name, "team": team, "pos": position})

    deduped = {row["player_id"]: row for row in players}
    players = sorted(deduped.values(), key=lambda row: (row["team"], row["name"]))
    if len(players) < 300:
        raise RuntimeError(f"Roster validation failed: expected at least 300 players, received {len(players)}")
    return {"as_of": generated_at, "source": "ESPN active team rosters", "players": players}


def refresh_schedule(generated_at: str, days: int = 5) -> dict:
    start = datetime.now().astimezone().date()

    def fetch_day(day) -> list[dict]:
        token = day.strftime("%Y%m%d")
        payload = fetch_json(
            f"https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates={token}"
        )
        games = []
        for event in payload.get("events") or []:
            competition = (event.get("competitions") or [{}])[0]
            sides = {item.get("homeAway"): item for item in competition.get("competitors") or []}
            away = normalize_team(sides.get("away", {}).get("team", {}).get("abbreviation"))
            home = normalize_team(sides.get("home", {}).get("team", {}).get("abbreviation"))
            if not away or not home:
                continue
            status = event.get("status", {})
            status_type = status.get("type", {})
            games.append({
                "game_id": str(event.get("id") or f"{day.isoformat()}_{away}_{home}"),
                "date": day.isoformat(),
                "away": away,
                "home": home,
                "tip": event.get("date"),
                "status": status_type.get("description") or status_type.get("detail"),
                "status_code": 3 if status_type.get("completed") else (2 if status_type.get("state") == "in" else 1),
                "away_score": int(sides.get("away", {}).get("score") or 0),
                "home_score": int(sides.get("home", {}).get("score") or 0),
                "period": int(status.get("period") or 0),
            })
        return games

    games: list[dict] = []
    with ThreadPoolExecutor(max_workers=days) as pool:
        futures = [pool.submit(fetch_day, start + timedelta(days=offset)) for offset in range(days)]
        for future in as_completed(futures):
            games.extend(future.result())
    games.sort(key=lambda row: (row["date"], row["tip"] or ""))
    return {
        "last_updated": generated_at,
        "date": start.isoformat(),
        "game_count": len(games),
        "games": games,
        "source": "ESPN scoreboard",
    }


def parse_lineup_players(list_html: str, team: str, lineup_status: str, generated_at: str) -> list[dict]:
    players = []
    pattern = re.compile(
        r'<li class="lineup__player[^>]*>.*?'
        r'<div class="lineup__pos"[^>]*>\s*([^<]+)\s*</div>.*?'
        r'<a[^>]*title="([^"]+)"[^>]*>.*?</a>(.*?)</li>',
        re.S,
    )
    for position, name, tail in pattern.findall(list_html):
        injury = re.search(r'class="lineup__inj"[^>]*>\s*([^<]+)', tail, re.S)
        injury_label = html.unescape(injury.group(1).strip()) if injury else ""
        status = {
            "Out": "OUT", "Doubt": "DOUBTFUL", "Ques": "QUESTIONABLE",
        }.get(injury_label, lineup_status)
        players.append({
            "name": html.unescape(name).strip(),
            "position": html.unescape(position).strip(),
            "status": status,
            "source": "rotowire",
            "updated_at": generated_at,
            "team": team,
        })
    return players[:5]


def refresh_lineups(schedule: dict, generated_at: str) -> dict:
    page = fetch_text("https://www.rotowire.com/basketball/nba-lineups.php")
    chunks = re.split(r'<div class="lineup is-nba[^>]*>', page)[1:]
    schedule_by_matchup = {
        (row["away"], row["home"]): row for row in schedule.get("games") or []
    }
    rows = []
    rotowire_games = 0
    for chunk in chunks:
        abbreviations = [normalize_team(value) for value in re.findall(r'<div class="lineup__abbr">\s*([^<]+)', chunk)]
        lists = re.findall(r'<ul class="lineup__list (is-visit|is-home)">(.*?)</ul>', chunk, re.S)
        if len(abbreviations) < 2 or len(lists) < 2:
            continue
        rotowire_games += 1
        away, home = abbreviations[:2]
        game = schedule_by_matchup.get((away, home))
        if not game:
            continue
        by_side = {side: body for side, body in lists}

        def status_for(body: str) -> str:
            return "CONFIRMED" if "is-confirmed" in body else "PROJECTED"

        away_body = by_side.get("is-visit", "")
        home_body = by_side.get("is-home", "")
        rows.append({
            "game_id": game["game_id"], "date": game["date"],
            "away": away, "home": home, "time": game.get("tip"),
            "away_lineup": parse_lineup_players(away_body, away, status_for(away_body), generated_at),
            "home_lineup": parse_lineup_players(home_body, home, status_for(home_body), generated_at),
        })
    expected_today = [row for row in schedule.get("games") or [] if row["date"] == schedule.get("date")]
    if expected_today and rotowire_games and not rows:
        raise RuntimeError("RotoWire returned lineup cards, but none matched the ESPN schedule")
    return {
        "last_updated": generated_at,
        "date": schedule.get("date"),
        "rows": rows,
        "game_count": len(expected_today),
        "games_with_lineups": len(rows),
        "source": "RotoWire starting lineups",
    }


def refresh_manifest(output: Path, generated_at: str) -> None:
    feeds = {}
    for path in sorted(output.glob("*.json")):
        if path.name == "manifest.json":
            continue
        body = path.read_bytes()
        feeds[path.stem] = {"bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()}
    now = datetime.now().astimezone()
    season = now.year + 1 if now.month >= 10 else now.year
    write_json(output / "manifest.json", {
        "schema_version": 3,
        "season": season,
        "generated_at": generated_at,
        "source": "desktop-nba-updater",
        "feeds": feeds,
    })


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DATA)
    args = parser.parse_args()
    generated_at = datetime.now(timezone.utc).isoformat()

    roster = refresh_roster(args.output, generated_at)
    schedule = refresh_schedule(generated_at)
    lineups = refresh_lineups(schedule, generated_at)

    # Write only after all downloads and validation succeed, avoiding partial publishes.
    write_json(args.output / "roster.json", roster)
    write_json(args.output / "schedule.json", schedule)
    write_json(args.output / "lineups.json", lineups)
    refresh_manifest(args.output, generated_at)
    print(f"Roster: {len(roster['players'])} players")
    print(f"Schedule: {len(schedule['games'])} games across the next 5 days")
    print(f"RotoWire: {len(lineups['rows'])} games with starting lineups")


if __name__ == "__main__":
    main()
