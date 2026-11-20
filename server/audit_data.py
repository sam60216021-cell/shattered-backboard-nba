"""Offline feed integrity and coverage audit; no provider or model requests."""
from collections import Counter
from datetime import datetime, timezone
import json
from pathlib import Path


def audit(data_dir):
    data_dir = Path(data_dir)
    def read(name):
        path = data_dir / (name + '.json')
        return json.loads(path.read_text()) if path.exists() else {}
    logs = read('player_logs')
    by_player = logs.get('logs_by_player', {})
    rows = [r for values in by_player.values() for r in values]
    roster = read('roster').get('players', [])
    schedule = read('schedule').get('games', [])
    lineups = read('lineups').get('rows', [])
    games = read('game_details').get('games_by_id', {})
    fields = ('mp_seconds', 'pts', 'reb', 'ast', 'stl', 'blk', 'tov', 'fgm', 'fga', 'three_pa', 'game_id')
    current = [r for r in rows if r.get('season') == logs.get('season')]
    duplicates = sum(n - 1 for n in Counter((pid, r.get('game_date')) for pid, values in by_player.items() for r in values).values() if n > 1)
    bad_lineups = [r.get('game_id') for r in lineups if not any(all(r.get(k) == g.get(k) for k in ('game_id', 'date', 'away', 'home')) for g in schedule)]
    bad_history = sum(1 for r in rows if r.get('game_id') in games and
                      (r.get('game_date') != games[r['game_id']].get('date') or
                       {r.get('team'), r.get('opponent')} != {games[r['game_id']].get('away'), games[r['game_id']].get('home')}))
    issues = []
    if duplicates: issues.append({'code': 'duplicate_player_dates', 'count': duplicates})
    if bad_lineups: issues.append({'code': 'lineup_schedule_mismatch', 'game_ids': bad_lineups})
    if bad_history: issues.append({'code': 'history_game_mismatch', 'count': bad_history})
    return {'last_updated': datetime.now(timezone.utc).isoformat(), 'source': 'Local published-feed audit',
            'source_updated_at': logs.get('last_updated'), 'issues': issues,
            'counts': {'roster': len(roster), 'logs': len(rows), 'current_season_logs': len(current),
                       'archived_games': len(games), 'events': sum(len(g.get('events', [])) for g in games.values()),
                       'games_without_events': sum(not g.get('events') for g in games.values()),
                       'games_without_ten_starters': sum(len(g.get('starters', [])) != 10 for g in games.values())},
            'missing_fields_all_history': {k: sum(r.get(k) is None for r in rows) for k in fields},
            'missing_fields_current_season': {k: sum(r.get(k) is None for r in current) for k in fields},
            'roster_without_direct_history': [{'player_id': r['player_id'], 'name': r.get('name')} for r in roster if not by_player.get(r['player_id'])],
            'unavailable_feeds': [n for n, key in [('team_advanced', 'teams'), ('team_position_splits', 'splits')] if not read(n).get(key)],
            'limitations': ['No direct history may mean no appearances or unresolved provider IDs; do not invent or fuzzy-match records.',
                           'Non-null legacy stats do not prove original source completeness; older imports may contain default zeros.',
                           'Full rotation stints and measured defender tracking are not collected.',
                           'App model outputs require phone sync; this audit does not verify the connected phone or prediction accuracy.']}


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument('--data', type=Path, default=Path(__file__).parent / 'data')
    args = parser.parse_args()
    print(json.dumps(audit(args.data), indent=2))
