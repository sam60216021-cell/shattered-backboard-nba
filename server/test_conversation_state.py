"""Consecutive request isolation and idempotency regressions; no paid calls."""
import hashlib
import json
import os
import sqlite3
import tempfile
import unittest
from unittest.mock import patch
from fastapi import HTTPException
import chat_api as chat
from test_chat_api import request, response


class ConversationStateTests(unittest.TestCase):
    def setUp(self):
        directory=tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        for p in [patch.object(chat,'LEDGER_PATH',directory.name+'/ledger.sqlite'),
                  patch.dict(os.environ,{'NBA_CHAT_TOKEN':'fixture','OPENAI_API_KEY':'fixture'})]:
            p.start();self.addCleanup(p.stop)

    def test_changed_question_reusing_id_never_receives_old_answer(self):
        with patch.object(chat,'run_analysis',return_value={'text':'old parlay','estimated_cost':.001}) as run:
            chat.analyze(request(),'fixture')
            with self.assertRaises(HTTPException) as error:
                chat.analyze(request(messages=[{'role':'user','content':'Explain pace; no picks.'}]),'fixture')
        self.assertEqual(error.exception.status_code,409)
        self.assertEqual(error.exception.detail['code'],'analysis_id_conflict')
        self.assertEqual(run.call_count,1)

    def test_identical_duplicate_replays_without_another_paid_call(self):
        with patch.object(chat,'run_analysis',return_value={'text':'answer','estimated_cost':.001}) as run:
            first=chat.analyze(request(),'fixture')
            second=chat.analyze(request(),'fixture')
        self.assertEqual(first,second)
        self.assertEqual(run.call_count,1)

    def test_changed_settings_and_instructions_cannot_replay_old_result(self):
        for change in [dict(web=True),dict(context={'players':[], 'now':'new-snapshot'})]:
            with self.subTest(change=change), patch.object(chat,'run_analysis',return_value={'estimated_cost':.001}):
                a=request(analysis_id=hashlib.sha256(str(change).encode()).hexdigest())
                chat.analyze(a,'fixture')
                with self.assertRaises(HTTPException):
                    chat.analyze(a.model_copy(update=change),'fixture')
        with patch.object(chat,'run_analysis',return_value={'estimated_cost':.001}):
            chat.analyze(request(),'fixture')
            with patch.object(chat,'INSTRUCTIONS',chat.INSTRUCTIONS+' New policy'), self.assertRaises(HTTPException):
                chat.analyze(request(),'fixture')

    def test_legacy_cache_without_fingerprint_is_not_reused(self):
        identity=hashlib.sha256(('fixture'+request().analysis_id).encode()).hexdigest()
        # Simulate storage created by the previous deployed version.
        with sqlite3.connect(chat.LEDGER_PATH) as db:
            db.execute('CREATE TABLE analyses (id TEXT PRIMARY KEY, created REAL, reserved REAL, result TEXT)')
            db.execute('INSERT INTO analyses VALUES (?,0,.001,?)',(identity,json.dumps({'text':'old'})))
        with patch.object(chat,'run_analysis') as run, self.assertRaises(HTTPException):
            chat.analyze(request(),'fixture')
        run.assert_not_called()

    def test_consecutive_questions_preserve_references_not_active_old_tasks(self):
        history=[{'role':'user','content':'Only build six-leg parlays; reject Player A.'},
                 {'role':'assistant','content':'Earlier picks: Player B and Player C.'}]
        requests=[request(analysis_id='turn-one-unique-001',messages=[history[0]],web=True),
                  request(analysis_id='turn-two-unique-002',messages=history+[{'role':'user','content':'Explain Player A minutes; no parlay.'}],web=False),
                  request(analysis_id='turn-three-unique-003',messages=history+[{'role':'user','content':'Compare those two players.'}],web=False)]
        for a in requests:
            call={'type':'function_call','name':'get_players','call_id':'one','arguments':'{"ids":["p"]}'}
            a.context={'players':[{'id':'p','stats':{}}]}
            with patch.object(chat,'post_openai',side_effect=[{'input_tokens':1000},response([call]),{'input_tokens':1200},response()]) as api:
                result=chat.analyze(a,'fixture')
            bodies=[c.args[1] for c in api.call_args_list if c.args[0]=='responses']
            # Capture the initial segment; continuation adds only this turn's outputs.
            current=[m for m in bodies[0]['input'] if m.get('role')=='user'][-1]
            self.assertEqual(current['content'],a.messages[-1]['content'])
            for body in bodies:
                self.assertEqual(body['instructions'],chat.INSTRUCTIONS)
                self.assertFalse(body['store'])
                self.assertNotIn('previous_response_id',body)
                self.assertNotIn('conversation',body)
                if not a.web:self.assertFalse(any(t['type']=='web_search' for t in body['tools']))
            self.assertEqual(sum(m.get('type') == 'function_call' for m in bodies[-1]['input']),1)
            self.assertEqual(result['tool_calls'],1)
            self.assertEqual(result['research_coverage']['player_ids_retrieved'],['p'])
            if len(a.messages)>1:
                prior=next(m['content'] for m in bodies[0]['input'] if m.get('content','').startswith('PRIOR CONVERSATION'))
                self.assertIn('Player B',prior)
                self.assertIn('reference only',prior)
                self.assertNotIn(a.messages[0],bodies[0]['input'])

    def test_missing_current_user_question_does_not_call_provider(self):
        for messages in [[],[{'role':'assistant','content':'Previous answer'}]]:
            with patch.object(chat,'post_openai') as api, self.assertRaises(HTTPException):
                chat.run_analysis(request(messages=messages))
            api.assert_not_called()
