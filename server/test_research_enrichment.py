import unittest
from research_enrichment import enrich_injuries, parse_history, defensive_research


class ResearchTests(unittest.TestCase):
    def test_injuries_match_provider_identity_and_keep_conflicts(self):
        roster = {'players':[{'player_id':'nba1','espn_id':'123','injuries':[]}]}
        payload = {'injuries':[{'injuries':[{'athlete':{'links':[{'href':'https://www.espn.com/nba/player/_/id/123/a'}]},'status':'Out','shortComment':'Questionable today','details':{'returnDate':'2026-11-22'}}]}]}
        self.assertEqual(enrich_injuries(roster,payload,'now'),1)
        report=roster['players'][0]['injuries'][0]
        self.assertEqual(report['status'],'Out')
        self.assertEqual(report['summary'],'Questionable today')
        self.assertEqual(report['estimated_return_date'],'2026-11-22')

    def test_history_uses_event_team_and_local_slate_date(self):
        payload={'labels':['MIN','PTS','FG'], 'events':{'g':{'gameDate':'2026-01-03T02:00:00+00:00','team':{'abbreviation':'GS'},'opponent':{'abbreviation':'NY'}}},
                 'seasonTypes':[{'displayName':'2025-26 Regular Season','categories':[{'events':[{'eventId':'g','stats':['20','12','5-10']}]}]}]}
        rows=parse_history(payload,{'player_id':'p','espn_id':'123','team':'BOS'},2026)
        self.assertEqual(rows[0]['game_date'],'2026-01-02')
        self.assertEqual(rows[0]['team'],'GSW')
        self.assertIsNone(rows[0]['stl'])
        self.assertEqual(rows[0]['fgm'],5)
        payload['seasonTypes'][0]['displayName']='2025-26 Preseason'
        self.assertEqual(parse_history(payload,{'player_id':'p','espn_id':'123'},2026),[])

    def test_defensive_estimate_uses_both_teams_and_observed_points(self):
        stats={'fieldGoalsMade-fieldGoalsAttempted':'40-80','threePointFieldGoalsMade-threePointFieldGoalsAttempted':'10-30','freeThrowsMade-freeThrowsAttempted':'10-20','offensiveRebounds':'10','totalTurnovers':'10'}
        games={'g':{'game_id':'g','date':'2026-11-01','team_box_scores':[{'team':'BOS','statistics':stats},{'team':'NYK','statistics':stats}]}}
        logs={'logs_by_player':{'p':[{'game_id':'g','season':2027}]}}
        result=defensive_research(games,logs,2027,'now')
        self.assertEqual(len(result['teams']),2)
        self.assertAlmostEqual(result['teams'][0]['estimated_defensive_rating'],10000/88.8)
        self.assertEqual(result['teams'][0]['opponent_points_per_game'],100)
        del stats['offensiveRebounds']
        self.assertEqual(defensive_research(games,logs,2027,'now')['teams'],[])

    def test_legacy_fill_preserves_values_and_rejects_conflicting_games(self):
        from research_enrichment import fill_missing_history
        rows=[{'player_id':'p','game_date':'2026-01-02','team':'BOS','opponent':'NYK','pts':20,'fgm':None}]
        observed=[dict(rows[0],fgm=8,game_id='g')]
        self.assertEqual(fill_missing_history(rows,observed),2)
        observed[0]['fgm']=9
        self.assertEqual(fill_missing_history(rows,observed),0)
        self.assertEqual(rows[0]['fgm'],8)
        rows[0]['fgm']=None
        observed[0]['pts']=21
        self.assertEqual(fill_missing_history(rows,observed),0)
