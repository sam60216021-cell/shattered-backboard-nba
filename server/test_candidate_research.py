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
        self.assertEqual(overview['candidates'][-1]['stats']['PTS']['projection'],159)
        self.assertTrue(all('logs' not in row for row in overview['candidates']))
        self.assertEqual(result['research_coverage']['player_ids_retrieved'],[])
        self.assertEqual(api.call_args.args[1]['max_output_tokens'],100000)

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
