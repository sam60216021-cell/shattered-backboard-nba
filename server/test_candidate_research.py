import json
import os
import unittest
from unittest.mock import patch
from fastapi import HTTPException
import chat_api as chat
from test_chat_api import request, response


class CandidateResearchTests(unittest.TestCase):
    def test_all_uploaded_candidates_have_comparable_evidence(self):
        players=[{'id': str(i), 'name': f'Player {i}', 'team': 'BOS', 'game': 'g',
                  'stats': {'PTS': {'projection': i, 'mean5': i-1}}, 'logs': [{'private_detail': 'not initial context'}]} for i in range(160)]
        with patch.object(chat,'post_openai',side_effect=[{'input_tokens':10000},response()]) as api:
            result=chat.run_analysis(request(context={'players':players}))
        overview=json.loads(api.call_args.args[1]['input'][0]['content'].removeprefix('APP EVIDENCE: '))
        self.assertEqual(len(overview['candidates']),160)
        self.assertEqual(next(p for p in overview['candidates'] if p['id']=='159')['stats']['PTS']['projection'],159)
        self.assertTrue(all('logs' not in row for row in overview['candidates']))
        self.assertEqual(result['research_coverage']['player_ids_retrieved'],[])
        self.assertEqual(api.call_args.args[1]['max_output_tokens'],100000)

    def test_minutes_and_previous_rank_do_not_determine_presentation(self):
        players = [dict(id='star', name='Z Player', game='a', minutes=38),
                   dict(id='role', name='A Player', game='a', minutes=19),
                   dict(id='other', name='B Player', game='b', minutes=25)]
        ordered = chat.candidate_presentation(players, 'Research rebounds')
        self.assertEqual([p['id'] for p in ordered], ['role', 'other', 'star'])
        changed = [{**p, 'minutes': 100 - p['minutes']} for p in reversed(players)]
        self.assertEqual([p['id'] for p in chat.candidate_presentation(changed, 'Research rebounds')],
                         ['role', 'other', 'star'])
        self.assertEqual(chat.candidate_presentation(players, 'Research Z Player')[0]['id'], 'star')

    def test_specialist_categories_and_omitted_pool_are_visible(self):
        stats = {stat: {'projection': 2, 'mean10': 3, 'mean5': 4, 'n': 10, 'sd': 1} for stat in chat.STAT_FIELDS}
        player = dict(id='role', name='Role Player', minutes=19, stats=stats)
        with patch.object(chat,'post_openai',side_effect=[{'input_tokens':1000},response()]) as api:
            result = chat.run_analysis(request(context={'players':[player], 'coverage':{'playersOmitted':25}}))
        overview = json.loads(api.call_args.args[1]['input'][0]['content'].removeprefix('APP EVIDENCE: '))
        self.assertEqual(overview['candidates'][0]['stats'], stats)
        self.assertEqual(overview['omittedCandidates'], 25)
        self.assertEqual(result['research_coverage']['candidates_omitted_by_client'],25)
        self.assertEqual(result['research_coverage']['evaluated_targets'], [])

    def test_actual_target_evaluations_are_recorded_separately_from_retrieval(self):
        calls = [{'type':'function_call','name':'get_players','call_id':'read',
                  'arguments':'{"ids":["star","role"]}'},
                 {'type':'function_call','name':'evaluate_player_target','call_id':'evaluate',
                  'arguments':'{"targets":[{"player_id":"role","stat":"BLK","target":0.5,"direction":"OVER"}]}'}]
        evaluated = dict(player_id='role',stat='BLK',target=.5,direction='OVER',
                         last_10={'games_available':10,'hits':7},last_5={'games_available':5,'hits':4})
        with patch.object(chat,'evaluate_target',return_value=evaluated), patch.object(chat,'post_openai',side_effect=[
            {'input_tokens':1000},response([calls[0]]),{'input_tokens':1200},response([calls[1]]),
            {'input_tokens':1400},response()]):
            result = chat.run_analysis(request(context={'players':[{'id':'star'},{'id':'role'}]}))
        self.assertEqual(result['research_coverage']['player_ids_retrieved'], ['role','star'])
        self.assertEqual(result['research_coverage']['evaluated_targets'], [evaluated])

    def test_research_continues_beyond_old_six_call_ceiling(self):
        replies=[]
        for i in range(8):
            replies += [{'input_tokens':1000},response([{'type':'function_call','name':'get_players','call_id':str(i),'arguments':'{"ids":["p"]}'}])]
        replies += [{'input_tokens':1000},response()]
        with patch.object(chat,'post_openai',side_effect=replies):
            result=chat.run_analysis(request(context={'players':[{'id':'p','stats':{}}]}))
        self.assertEqual(result['stop_reason'],'completed')
        self.assertEqual(result['tool_calls'],8)
        self.assertEqual(result['research_coverage']['player_ids_retrieved'],['p'])
        self.assertLess(result['estimated_cost'],.25)

    def test_invalid_output_config_fails_without_provider_call(self):
        for value in ['128001','0','bad']:
            with patch.dict(os.environ,{'NBA_CHAT_MAX_OUTPUT_TOKENS':value}), patch.object(chat,'post_openai') as api:
                with self.assertRaises(HTTPException): chat.run_analysis(request())
                api.assert_not_called()

    def test_configured_output_is_applied(self):
        with patch.dict(os.environ,{'NBA_CHAT_MAX_OUTPUT_TOKENS':'120000'}), patch.object(chat,'post_openai',side_effect=[{'input_tokens':1000},response()]) as api:
            chat.run_analysis(request())
        self.assertEqual(api.call_args.args[1]['max_output_tokens'],120000)
