"""Independent research and consecutive category regressions; no paid calls."""
import json
import unittest
from unittest.mock import patch

import ai_data
import chat_api as chat
from research_targets import evaluate_target
from test_chat_api import request, response


class ResearchTargetTests(unittest.TestCase):
    def setUp(self):
        self.rows = [{"game_date": f"2026-11-{i:02d}", "opponent": "NYK",
                      "pts": i, "reb": i, "ast": i, "three_p": i} for i in range(1, 11)]
        feed = patch.object(ai_data, "feed", side_effect=lambda name:
                            {"logs_by_player": {"p": self.rows}} if name == "player_logs" else {})
        feed.start()
        self.addCleanup(feed.stop)

    def test_exact_rates_use_latest_games_and_strict_direction(self):
        for stat in ("PTS", "REB", "AST", "3PM"):
            for direction, hits, recent in (("OVER", 5, 5), ("UNDER", 4, 0)):
                result = evaluate_target(ai_data.DataAccess(), "p", stat, 5, direction)
                self.assertEqual(result["last_10"]["hits"], hits)
                self.assertEqual(result["last_10"]["pushes"], 1)
                self.assertEqual(result["last_10"]["hit_rate"], hits / 10)
                self.assertEqual(result["last_5"]["hits"], recent)
                self.assertTrue(result["last_5"]["complete_window"])

    def test_missing_conflicting_and_short_history_not_invented(self):
        self.rows[-1]["pts"] = None
        self.rows[-2]["app_differences"] = {"pts": 99}
        result = evaluate_target(ai_data.DataAccess(), "p", "PTS", 5, "OVER")
        self.assertEqual(result["last_5"]["observations"], 3)
        self.assertEqual(result["last_5"]["missing_observations"], 2)
        self.assertFalse(result["last_5"]["complete_window"])
        empty = evaluate_target(ai_data.DataAccess(), "absent", "PTS", 5, "OVER")
        self.assertIsNone(empty["last_10"]["hit_rate"])
        self.rows[:] = self.rows[:2]
        short = evaluate_target(ai_data.DataAccess(), "p", "PTS", 5, "OVER")
        self.assertEqual(short["last_10"]["observations"], 2)
        self.assertFalse(short["last_10"]["complete_window"])

    def test_invalid_targets_are_not_usable(self):
        for target in (True, float("nan"), float("inf"), -1, "5"):
            self.assertIn("error", evaluate_target(ai_data.DataAccess(), "p", "PTS", target, "OVER"))

    def test_missing_candidate_allows_alternative_tool_continuation(self):
        calls = [{"type": "function_call", "name": "evaluate_player_target", "call_id": player,
                  "arguments": json.dumps(dict(player_id=player, stat="REB", target=5, direction="OVER"))}
                 for player in ("missing", "p")]
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response([calls[0]]),
                          {"input_tokens": 1200}, response([calls[1]]),
                          {"input_tokens": 1400}, response()]) as api:
            result = chat.run_analysis(request(messages=[{"role": "user", "content": "Research up to two rebound candidates."}]))
        outputs = [m for m in api.call_args.args[1]["input"] if m.get("type") == "function_call_output"]
        self.assertIsNone(json.loads(outputs[0]["output"])["last_10"]["hit_rate"])
        self.assertEqual(json.loads(outputs[1]["output"])["last_10"]["hit_rate"], .5)
        self.assertEqual(result["stop_reason"], "completed")
        self.assertEqual(result["research_coverage"]["player_ids_retrieved"], ["p"])

    def test_consecutive_categories_keep_current_task_and_fresh_target_results(self):
        history = [{"role": "user", "content": "Build six legs; reject Player P."},
                   {"role": "assistant", "content": "Previous research mentioned Player P."}]
        for index, (stat, category) in enumerate((("PTS", "points"), ("REB", "rebounds"),
                                                 ("AST", "assists"), ("3PM", "three-pointers"))):
            question = {"role": "user", "content": f"Research Player P {category}, target 5 OVER."}
            call = {"type": "function_call", "name": "evaluate_player_target", "call_id": f"target-{index}",
                    "arguments": json.dumps(dict(player_id="p", stat=stat, target=5, direction="OVER"))}
            with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response([call]),
                              {"input_tokens": 1300}, response()]) as api:
                result = chat.run_analysis(request(messages=(history + [question])[-8:], web=index % 2 == 1))
            bodies = [c.args[1] for c in api.call_args_list if c.args[0] == "responses"]
            self.assertEqual(result["stop_reason"], "completed")
            self.assertEqual(result["tool_calls"], 1)
            for body in bodies:
                self.assertEqual(body["instructions"], chat.INSTRUCTIONS)
                self.assertEqual([m for m in body["input"] if m.get("role") == "user"][-1], question)
            outputs = [m for m in bodies[-1]["input"] if m.get("type") == "function_call_output"]
            self.assertEqual(len(outputs), 1)
            evaluated = json.loads(outputs[0]["output"])
            self.assertEqual(evaluated["stat"], stat)
            self.assertEqual(evaluated["last_10"]["hits"], 5)
            history += [question, {"role": "assistant", "content": f"Player P {category} research."}]

    def test_research_policy_has_no_automatic_combination_requirement(self):
        self.assertNotIn("parlay", chat.INSTRUCTIONS.lower())
        self.assertNotIn("3-leg", chat.INSTRUCTIONS)
        self.assertIn("exact numerical target", chat.INSTRUCTIONS)
        self.assertIn("continue evaluating alternatives", chat.INSTRUCTIONS)
        self.assertIn("unknown, never automatically injured or healthy", chat.INSTRUCTIONS)
        self.assertIn("not carry earlier task-specific", chat.INSTRUCTIONS)


if __name__ == "__main__":
    unittest.main()
