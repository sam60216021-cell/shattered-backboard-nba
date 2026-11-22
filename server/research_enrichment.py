"""Source-backed research supplements; no prediction weights or market data."""
from collections import defaultdict
from datetime import datetime
import math
import re
from zoneinfo import ZoneInfo


def enrich_injuries(roster, payload, retrieved_at):
    by_id = {r.get('espn_id'): r for r in roster['players'] if r.get('espn_id')}
    count = 0
    for team in payload.get('injuries', []):
        for item in team.get('injuries', []):
            athlete = item.get('athlete') or {}
            links = [v.get('href', '') for v in athlete.get('links', [])]
            match = next((re.search(r'/id/(\d+)', url) for url in links if re.search(r'/id/(\d+)', url)), None)
            eid = str(athlete.get('id') or (match.group(1) if match else ''))
            if eid not in by_id:
                continue
            details = item.get('details') or {}
            record = {'status': item.get('status'), 'reported_at': item.get('date'),
                      'summary': item.get('shortComment'), 'report': item.get('longComment'),
                      'injury_type': details.get('type'), 'location': details.get('location'),
                      'detail': details.get('detail'), 'estimated_return_date': details.get('returnDate'),
                      'source_url': f'https://www.espn.com/nba/player/_/id/{eid}',
                      'retrieved_at': retrieved_at,
                      'limitations': 'Source report, not medical clearance. Return date is an estimate; status and narrative may conflict.'}
            by_id[eid]['injuries'] = [record]
            count += 1
    return count


def parse_history(payload, player, season):
    """Exact provider ID supplied by roster; retain event team (not current team)."""
    rows = {}
    def numeric(value):
        try:
            result = float(value)
            return result if math.isfinite(result) else None
        except (ValueError, TypeError): return None
    for part in payload.get('seasonTypes', []):
        # Keep season types explicit; do not mix preseason/play-in into season aggregates.
        if part.get('displayName') != f'{season-1}-{str(season)[-2:]} Regular Season':
            continue
        for category in part.get('categories', []):
            for entry in category.get('events', []):
                gid = str(entry.get('eventId') or '')
                event = payload.get('events', {}).get(gid, {})
                stats = dict(zip(payload.get('labels', []), entry.get('stats', [])))
                team = (event.get('team') or {}).get('abbreviation')
                opponent = (event.get('opponent') or {}).get('abbreviation')
                if not event.get('gameDate') or not team or not opponent or numeric(stats.get('MIN')) is None:
                    continue
                from update_server import normalize_team
                row = {'player_id': player['player_id'], 'game_id': gid, 'season': season,
                       'game_date': datetime.fromisoformat(event['gameDate'].replace('Z', '+00:00')).astimezone(ZoneInfo('America/New_York')).date().isoformat(),
                       'team': normalize_team(team), 'opponent': normalize_team(opponent),
                       'mp_seconds': numeric(stats['MIN']) * 60,
                       'source_url': f"https://www.espn.com/nba/player/gamelog/_/id/{player['espn_id']}",
                       'plus_minus': None}
                for label, field in [('PTS','pts'),('REB','reb'),('AST','ast'),('STL','stl'),('BLK','blk'),('TO','tov')]:
                    row[field] = numeric(stats.get(label))
                for label, fields in [('FG',('fgm','fga')),('3PT',('three_p','three_pa')),('FT',('ftm','fta'))]:
                    pair = str(stats.get(label, '')).split('-')
                    for i, field in enumerate(fields): row[field] = numeric(pair[i]) if len(pair)==2 else None
                rows[gid] = row
    return list(rows.values())


def defensive_research(games, logs, season, retrieved_at):
    """Observed opponent production and box-score possession estimates, AI-only."""
    teams = defaultdict(list)
    def number(value):
        try: return float(value)
        except (TypeError, ValueError): return None
    valid_ids = {r.get("game_id") for rows in logs.get("logs_by_player", {}).values() for r in rows if r.get("season") == season}
    for game in games.values():
        boxes = game.get('team_box_scores', [])
        if len(boxes) != 2: continue
        # Limit to games known to belong to the requested season.
        if game.get('game_id') not in valid_ids: continue
        parsed = []
        for box in boxes:
            s = box.get('statistics', {})
            def pair(key):
                v = str(s.get(key, '')).split('-')
                return [number(x) for x in v] if len(v)==2 else [None,None]
            fg, fga = pair('fieldGoalsMade-fieldGoalsAttempted'); three, _ = pair('threePointFieldGoalsMade-threePointFieldGoalsAttempted'); ft, fta = pair('freeThrowsMade-freeThrowsAttempted')
            oreb = number(s.get('offensiveRebounds')); tov = number(s.get('totalTurnovers'))
            if any(v is None for v in [fg,fga,three,ft,fta,oreb,tov]): break
            parsed.append((box['team'], 2*fg+three+ft, fga-oreb+.44*fta+tov))
        if len(parsed)!=2: continue
        poss = (parsed[0][2]+parsed[1][2])/2
        if poss <= 0: continue
        for own, other in [(parsed[0],parsed[1]),(parsed[1],parsed[0])]:
            teams[own[0]].append({'game_id':game['game_id'],'date':game['date'],'points':own[1],'allowed':other[1],'possessions':poss})
    positions = defaultdict(list)
    for rows in logs.get('logs_by_player', {}).values():
        for row in rows:
            if row.get('season') != season or not row.get('opponent') or not row.get('position') or not row.get('mp_seconds'):
                continue
            positions[(row['opponent'], row['position'])].append(row)
    result=[]
    for team, rows in sorted(teams.items()):
        possessions=sum(r['possessions'] for r in rows)
        result.append({'team':team,'games':len(rows),'start_date':min(r['date'] for r in rows),'end_date':max(r['date'] for r in rows),
                       'opponent_points_per_game':sum(r['allowed'] for r in rows)/len(rows),
                       'estimated_defensive_rating':100*sum(r['allowed'] for r in rows)/possessions,
                       'estimated_offensive_rating':100*sum(r['points'] for r in rows)/possessions,
                       'opponent_position_observations': [
                           {'position': pos, 'player_games': len(samples),
                            'start_date': min(r['game_date'] for r in samples), 'end_date': max(r['game_date'] for r in samples),
                            'per_player_game_means': {stat: sum(r[stat] for r in samples if isinstance(r.get(stat), (int,float))) / sum(isinstance(r.get(stat), (int,float)) for r in samples)
                                                      for stat in ('pts','reb','ast','three_p','mp_seconds') if any(isinstance(r.get(stat), (int,float)) for r in samples)}}
                           for (opponent, pos), samples in sorted(positions.items()) if opponent == team]})
    return {'last_updated':retrieved_at,'season':season,'teams':result,
            'method':'Possessions estimated as mean of both teams: FGA - OREB + 0.44*FTA + total turnovers. Ratings are points per 100 estimated possessions across collected games only.',
            'limitations':'Not official NBA ratings. Position observations use source-listed box-score positions and per-player-game averages, not actual defensive assignments; limited to rows with observed positions. Not used to replace app prediction inputs.'}


def fill_missing_history(existing, observed):
    """Fill absent fields only on an exact player/date/team/opponent match."""
    fields = ('game_id','fgm','three_pa','plus_minus')
    index = {(r.get('player_id'), r.get('game_date'), r.get('team'), r.get('opponent')): r for r in observed}
    changed = 0
    for row in existing:
        match = index.get((row.get('player_id'), row.get('game_date'), row.get('team'), row.get('opponent')))
        if not match: continue
        # Do not join two sources whose overlapping box-score totals disagree.
        if any(row.get(k) is not None and match.get(k) is not None and row[k] != match[k] for k in ('pts','reb','ast','fga','ftm')):
            continue
        for key in fields:
            if row.get(key) is None and match.get(key) is not None:
                row[key] = match[key]
                changed += 1
    return changed
