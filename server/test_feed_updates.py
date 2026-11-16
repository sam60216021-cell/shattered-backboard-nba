import unittest
from unittest.mock import patch
import update_server as updater
import ai_data


class FeedUpdateTests(unittest.TestCase):
    def test_lineups_match_today_not_future_repeat(self):
        html = '<div class="lineup is-nba"><div class="lineup__abbr">BOS</div><div class="lineup__abbr">NYK</div><ul class="lineup__list is-visit"></ul><ul class="lineup__list is-home"></ul>'
        schedule = {"date": "2026-11-16", "games": [
            {"game_id": "today", "date": "2026-11-16", "away": "BOS", "home": "NYK"},
            {"game_id": "later", "date": "2026-11-18", "away": "BOS", "home": "NYK"}]}
        with patch.object(updater, 'fetch_text', return_value=html):
            result = updater.refresh_lineups(schedule, 'now')
        self.assertEqual(result['rows'][0]['game_id'], 'today')

    def test_observed_events_and_missing_data(self):
        summary = {'plays': [{'id': '1', 'type': {'text': 'Substitution'}, 'text': 'A enters for B', 'period': {'number': 1}, 'clock': {'displayValue': '5:00'}}], 'odds': {'line': 100}}
        game = updater.normalize_game_details(summary, 'g', '2026-11-16', 'BOS', 'NYK', 'now', {})
        self.assertNotIn('odds', game)
        self.assertEqual(game['starters'], [])
        self.assertIsNone(game['events'][0]['away_score'])
        with patch.object(ai_data, 'feed', return_value={'games_by_id': {'g': game}}):
            query = ai_data.DataAccess()
            self.assertEqual(query.query({'kind': 'substitutions', 'game_id': 'g'})['total'], 1)
            self.assertEqual(query.query({'kind': 'game_details', 'team': 'BOS'})['rows'][0]['event_count'], 1)
            self.assertFalse(query.query({'kind': 'play_by_play', 'game_id': 'missing'})['available'])
            self.assertIn('error', query.query({'kind': 'play_by_play'}))

    def test_event_pagination(self):
        with patch.object(ai_data, 'feed', return_value={'games_by_id': {'g': {'events': [{'type': 'Shot'}] * 51}}}):
            result = ai_data.DataAccess().query({'kind': 'play_by_play', 'game_id': 'g', 'limit': 50})
        self.assertEqual(len(result['rows']), 50)
        self.assertEqual(result['next_offset'], 50)

    def test_injury_filter_keeps_report_timestamp(self):
        with patch.object(ai_data, 'feed', return_value={'as_of': 'now', 'players': [
            {'player_id': 'p', 'team': 'BOS', 'injuries': [{'status': 'Day-To-Day', 'reported_at': 'yesterday'}]},
            {'player_id': 'q', 'team': 'BOS', 'injuries': []}]}):
            result = ai_data.DataAccess().query({'kind': 'injuries', 'team': 'BOS'})
        self.assertEqual(result['total'], 1)
        self.assertEqual(result['rows'][0]['injuries'][0]['reported_at'], 'yesterday')
