#!/usr/bin/env python3
"""Refresh the checked-in NBA feeds used by the Render service.

The Mac is the collector: ESPN supplies the schedule and full active rosters,
while RotoWire supplies projected/confirmed starting lineups. Validated JSON is
written atomically into ``server/data`` before Git deploys it to Render.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
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


def season_end_year(now: datetime | None = None) -> int:
    now = now or datetime.now().astimezone()
    return now.year + 1 if now.month >= 10 else now.year


def number(value, default: float = 0.0) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return default


def made_attempted(value: str | None) -> tuple[float, float]:
    try:
        made, attempted = str(value or "0-0").split("-", 1)
        return number(made), number(attempted)
    except ValueError:
        return 0.0, 0.0


def minutes_seconds(value: str | None) -> float:
    text = str(value or "0").strip()
    if ":" in text:
        minutes, seconds = text.split(":", 1)
        return number(minutes) * 60 + number(seconds)
    return number(text) * 60


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


def refresh_player_logs(output: Path, generated_at: str, season: int, lookback_days: int = 7) -> dict:
    """Merge recent completed ESPN box scores into the historical player log feed."""
    existing_path = output / "player_logs.json"
    try:
        existing_payload = json.loads(existing_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        existing_payload = {"logs_by_player": {}}
    existing_by_player = existing_payload.get("logs_by_player") or {}

    known_players = load_existing_players(output)
    today = datetime.now().astimezone().date()
    completed: list[tuple[dict, dict]] = []
    for offset in range(lookback_days):
        day = today - timedelta(days=offset)
        token = day.strftime("%Y%m%d")
        scoreboard = fetch_json(
            f"https://site.api.espn.com/apis/site/v2/sports/basketball/nba/scoreboard?dates={token}"
        )
        for event in scoreboard.get("events") or []:
            status_type = (event.get("status") or {}).get("type") or {}
            if not status_type.get("completed"):
                continue
            competition = (event.get("competitions") or [{}])[0]
            completed.append((event, competition))

    merged: dict[str, list[dict]] = {
        str(player_id): list(rows or []) for player_id, rows in existing_by_player.items()
    }
    imported_games = 0
    imported_rows = 0
    for event, competition in completed:
        game_id = str(event.get("id") or "")
        if not game_id:
            continue
        summary = fetch_json(
            f"https://site.api.espn.com/apis/site/v2/sports/basketball/nba/summary?event={game_id}"
        )
        competitors = {row.get("homeAway"): row for row in competition.get("competitors") or []}
        away = normalize_team(competitors.get("away", {}).get("team", {}).get("abbreviation"))
        home = normalize_team(competitors.get("home", {}).get("team", {}).get("abbreviation"))
        game_date = str(event.get("date") or "")[:10]
        game_rows = 0

        for team_block in ((summary.get("boxscore") or {}).get("players") or []):
            team = normalize_team((team_block.get("team") or {}).get("abbreviation"))
            opponent = home if team == away else away
            for stat_group in team_block.get("statistics") or []:
                labels = stat_group.get("labels") or []
                for athlete_row in stat_group.get("athletes") or []:
                    if athlete_row.get("didNotPlay"):
                        continue
                    athlete = athlete_row.get("athlete") or {}
                    name = athlete.get("displayName")
                    values = athlete_row.get("stats") or []
                    if not name or not values:
                        continue
                    stats = dict(zip(labels, values))
                    player_id = str(
                        (known_players.get(normalized_name(name)) or {}).get("player_id")
                        or athlete.get("id") or ""
                    )
                    if not player_id:
                        continue
                    fgm, fga = made_attempted(stats.get("FG"))
                    three_p, three_pa = made_attempted(stats.get("3PT"))
                    ftm, fta = made_attempted(stats.get("FT"))
                    row = {
                        "game_id": game_id,
                        "game_date": game_date,
                        "player_id": player_id,
                        "season": season,
                        "team": team,
                        "opponent": opponent,
                        "mp_seconds": minutes_seconds(stats.get("MIN")),
                        "pts": number(stats.get("PTS")),
                        "reb": number(stats.get("REB")),
                        "ast": number(stats.get("AST")),
                        "stl": number(stats.get("STL")),
                        "blk": number(stats.get("BLK")),
                        "tov": number(stats.get("TO")),
                        "fgm": fgm,
                        "fga": fga,
                        "three_p": three_p,
                        "three_pa": three_pa,
                        "ftm": ftm,
                        "fta": fta,
                        "plus_minus": number(stats.get("+/-")),
                    }
                    rows = merged.setdefault(player_id, [])
                    rows[:] = [old for old in rows if not (
                        str(old.get("game_id") or "") == game_id
                        or (str(old.get("game_date") or "") == game_date
                            and normalize_team(old.get("team")) == team)
                    )]
                    rows.append(row)
                    game_rows += 1
        if game_rows:
            imported_games += 1
            imported_rows += game_rows

    for rows in merged.values():
        rows.sort(key=lambda row: str(row.get("game_date") or ""), reverse=True)
    return {
        "season": season,
        "last_updated": generated_at,
        "source": "ESPN completed game box scores",
        "games_imported": imported_games,
        "rows_imported": imported_rows,
        "logs_by_player": merged,
    }


def rebuild_stats(logs_payload: dict, roster: dict, generated_at: str, season: int) -> dict:
    roster_by_id = {str(row.get("player_id")): row for row in roster.get("players") or []}
    players = []
    for player_id, all_rows in (logs_payload.get("logs_by_player") or {}).items():
        rows = [row for row in all_rows if int(row.get("season") or 0) == season and number(row.get("mp_seconds")) > 0]
        if not rows:
            continue
        totals = {key: sum(number(row.get(key)) for row in rows) for key in (
            "mp_seconds", "pts", "reb", "ast", "stl", "blk", "tov",
            "fgm", "fga", "three_p", "three_pa", "ftm", "fta", "plus_minus",
        )}
        gp = len(rows)
        info = roster_by_id.get(str(player_id), {})
        players.append({
            "player_id": str(player_id),
            "name": info.get("name") or str(player_id),
            "team": info.get("team") or rows[0].get("team"),
            "gp": gp,
            "min": round(totals["mp_seconds"] / 60 / gp, 1),
            "pts": round(totals["pts"] / gp, 1),
            "reb": round(totals["reb"] / gp, 1),
            "ast": round(totals["ast"] / gp, 1),
            "stl": round(totals["stl"] / gp, 1),
            "blk": round(totals["blk"] / gp, 1),
            "tov": round(totals["tov"] / gp, 1),
            "fg_pct": round(totals["fgm"] / totals["fga"], 3) if totals["fga"] else 0,
            "fg3_pct": round(totals["three_p"] / totals["three_pa"], 3) if totals["three_pa"] else 0,
            "ft_pct": round(totals["ftm"] / totals["fta"], 3) if totals["fta"] else 0,
            "plus_minus": round(totals["plus_minus"] / gp, 1),
        })
    players.sort(key=lambda row: (row.get("team") or "", row.get("name") or ""))
    return {"season": season, "last_updated": generated_at, "source": "ESPN box score aggregates", "players": players}


def rebuild_player_advanced(logs_payload: dict, roster: dict, generated_at: str, season: int) -> dict:
    team_possessions: dict[tuple[str, str], float] = defaultdict(float)
    current: dict[str, list[dict]] = {}
    for player_id, all_rows in (logs_payload.get("logs_by_player") or {}).items():
        rows = [row for row in all_rows if int(row.get("season") or 0) == season and number(row.get("mp_seconds")) > 0]
        if rows:
            current[str(player_id)] = rows
        for row in rows:
            key = (normalize_team(row.get("team")), str(row.get("game_date") or ""))
            team_possessions[key] += number(row.get("fga")) + 0.44 * number(row.get("fta")) + number(row.get("tov"))
    roster_by_id = {str(row.get("player_id")): row for row in roster.get("players") or []}
    players = []
    for player_id, rows in current.items():
        minutes = sum(number(row.get("mp_seconds")) for row in rows) / 60
        used = sum(number(row.get("fga")) + 0.44 * number(row.get("fta")) + number(row.get("tov")) for row in rows)
        shares = []
        for row in rows:
            key = (normalize_team(row.get("team")), str(row.get("game_date") or ""))
            total = team_possessions.get(key, 0)
            if total:
                shares.append((number(row.get("fga")) + 0.44 * number(row.get("fta")) + number(row.get("tov"))) / total)
        info = roster_by_id.get(player_id, {})
        players.append({
            "player_id": player_id,
            "name": info.get("name") or player_id,
            "team": info.get("team") or rows[0].get("team"),
            "games": len(rows),
            "minutes_per_game": round(minutes / len(rows), 2),
            "estimated_usage_pct": round(100 * sum(shares) / len(shares), 2) if shares else None,
            "possessions_used_per_36": round(36 * used / minutes, 2) if minutes else None,
        })
    players.sort(key=lambda row: (row.get("team") or "", row.get("name") or ""))
    return {"season": season, "last_updated": generated_at, "method": "FGA + 0.44*FTA + TOV share", "players": players}


def refresh_standings(generated_at: str, season: int) -> dict:
    payload = fetch_json(
        f"https://site.api.espn.com/apis/v2/sports/basketball/nba/standings?season={season}"
    )
    rows = []
    for conference in payload.get("children") or []:
        conference_name = str(conference.get("name") or "").replace("ern Conference", "")
        for entry in ((conference.get("standings") or {}).get("entries") or []):
            team = entry.get("team") or {}
            stats = {str(stat.get("name")): stat for stat in entry.get("stats") or []}
            value = lambda name: number((stats.get(name) or {}).get("value"))
            display = lambda name: str((stats.get(name) or {}).get("displayValue") or "")
            rows.append({
                "team_id": int(team.get("id") or 0),
                "team_name": team.get("name"),
                "team_city": team.get("location"),
                "abbr": normalize_team(team.get("abbreviation")),
                "conference": conference_name,
                "division": "",
                "wins": int(value("wins")),
                "losses": int(value("losses")),
                "pct": value("winPercent"),
                "games_back": value("gamesBehind"),
                "home_record": display("Home"),
                "road_record": display("Road"),
                "last_10": display("Last Ten Games"),
                "streak": display("streak"),
                "points_pg": value("avgPointsFor"),
                "opp_points_pg": value("avgPointsAgainst"),
                "clinch_indicator": "",
            })
    if len(rows) != 30:
        raise RuntimeError(f"Standings validation failed: expected 30 teams, received {len(rows)}")
    return {"season": season, "last_updated": generated_at, "source": "ESPN standings", "standings": rows}


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
    season = season_end_year()

    roster = refresh_roster(args.output, generated_at)
    schedule = refresh_schedule(generated_at)
    lineups = refresh_lineups(schedule, generated_at)
    player_logs = refresh_player_logs(args.output, generated_at, season)
    stats = rebuild_stats(player_logs, roster, generated_at, season)
    player_advanced = rebuild_player_advanced(player_logs, roster, generated_at, season)
    standings = refresh_standings(generated_at, season)

    # Write only after all downloads and validation succeed, avoiding partial publishes.
    write_json(args.output / "roster.json", roster)
    write_json(args.output / "schedule.json", schedule)
    write_json(args.output / "lineups.json", lineups)
    write_json(args.output / "player_logs.json", player_logs)
    write_json(args.output / "stats.json", stats)
    write_json(args.output / "player_advanced.json", player_advanced)
    write_json(args.output / "standings.json", standings)
    refresh_manifest(args.output, generated_at)
    print(f"Roster: {len(roster['players'])} players")
    print(f"Schedule: {len(schedule['games'])} games across the next 5 days")
    print(f"RotoWire: {len(lineups['rows'])} games with starting lineups")
    print(f"Game logs: {player_logs['rows_imported']} rows from {player_logs['games_imported']} completed games")
    print(f"Current-season stats: {len(stats['players'])} players")
    print(f"Standings: {len(standings['standings'])} teams")


if __name__ == "__main__":
    main()
