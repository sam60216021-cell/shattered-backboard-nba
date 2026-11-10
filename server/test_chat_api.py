"""Offline cost/security regression checks. Never use a real provider key."""
import os
import tempfile
import unittest
from unittest.mock import patch
from fastapi import HTTPException
import chat_api as chat


def request(**changes):
    values = dict(analysis_id="offline-analysis-001", context={"players": []},
                  messages=[{"role": "user", "content": "Build three legs"}])
    values.update(changes)
    return chat.Analysis(**values)


def response(output=None, **extra):
    return {"id": "fixture", "model": "gpt-6-luna", "status": "completed",
            "usage": {"input_tokens": 1000, "output_tokens": 100},
            "output": output or [{"type": "message", "content": [{"text": "Not enough eligible players."}]}], **extra}


class ChatTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        path = patch.object(chat, "LEDGER_PATH", directory.name + "/ledger.sqlite")
        path.start()
        self.addCleanup(path.stop)

    def test_free_storage_ignores_legacy_paid_disk_setting(self):
        for legacy in ("", "/unavailable/paid/disk/ledger.sqlite"):
            with self.subTest(legacy=legacy), patch.dict(os.environ, {
                "NBA_CHAT_LEDGER": legacy, "NBA_CHAT_TOKEN": "fixture-token",
                "OPENAI_API_KEY": "fixture-not-a-key"}), patch.object(chat, "run_analysis", return_value={"estimated_cost": .001}):
                self.assertEqual(chat.analyze(request(), "fixture-token")["estimated_cost"], .001)

    def test_invalid_settings_fail_before_provider_calls(self):
        for name in ("NBA_CHAT_DAILY_USD", "NBA_SEARCH_COST_USD"):
            for value in ("nan", "inf", "-1", "0", "bad", ""):
                with self.subTest(name=name, value=value), patch.dict(os.environ, {
                    name: value, "NBA_CHAT_TOKEN": "fixture-token", "OPENAI_API_KEY": "fixture"}), patch.object(chat, "post_openai") as api:
                    with self.assertRaises(HTTPException) as error:
                        chat.analyze(request(), "fixture-token")
                    self.assertEqual(error.exception.status_code, 503)
                    self.assertEqual(error.exception.detail["code"], "invalid_cost_settings")
                    api.assert_not_called()

    def test_unwritable_temporary_storage_fails_without_spending(self):
        with patch.object(chat, "LEDGER_PATH", "/nonexistent-parent/ledger.sqlite"), patch.dict(os.environ, {
            "NBA_CHAT_TOKEN": "fixture-token", "OPENAI_API_KEY": "fixture"}), patch.object(chat, "post_openai") as api:
            with self.assertRaises(HTTPException) as error:
                chat.analyze(request(), "fixture-token")
            self.assertEqual(error.exception.detail["code"], "temporary_accounting_unavailable")
            api.assert_not_called()

    def test_missing_provider_key_is_distinguishable(self):
        with patch.dict(os.environ, {"NBA_CHAT_TOKEN": "fixture-token", "OPENAI_API_KEY": ""}):
            with self.assertRaises(HTTPException) as error:
                chat.authorize("fixture-token")
            self.assertEqual(error.exception.detail["code"], "missing_openai_key")

    def test_interrupted_duplicate_does_not_retry(self):
        with patch.dict(os.environ, {"NBA_CHAT_TOKEN": "fixture-token", "OPENAI_API_KEY": "fixture"}), patch.object(chat, "run_analysis", side_effect=TimeoutError()) as run:
            with self.assertRaises(HTTPException):
                chat.analyze(request(), "fixture-token")
            with self.assertRaises(HTTPException) as error:
                chat.analyze(request(), "fixture-token")
            self.assertEqual(error.exception.status_code, 409)
            self.assertEqual(run.call_count, 1)

    def test_luna_output_allowance_survives_large_tool_response(self):
        call = {"type": "function_call", "name": "get_players", "call_id": "large", "arguments": '{"ids":[]}'}
        first = response([call], usage={"input_tokens": 1000, "output_tokens": 20000,
                                       "output_tokens_details": {"reasoning_tokens": 19000}})
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, first,
                {"input_tokens": 1200}, response()]) as api, self.assertLogs("nba.chat") as logs:
            result = chat.run_analysis(request())
        generations = [c.args[1] for c in api.call_args_list if c.args[0] == "responses"]
        self.assertEqual([b["max_output_tokens"] for b in generations], [50000, 50000])
        self.assertEqual(result["output_tokens"], 20100)
        self.assertIn("reasoning_tokens=19000", str(logs.output))
        self.assertIn("status=completed", str(logs.output))
        self.assertIn("estimated_cost=", str(logs.output))

    def test_output_limit_withholds_predictions_without_retry(self):
        partial = response(status="incomplete", incomplete_details={"reason": "max_output_tokens"},
                           usage={"input_tokens": 1000, "output_tokens": 50000,
                                  "output_tokens_details": {"reasoning_tokens": 49000}})
        partial["output"] = [{"type": "message", "content": [{"text": "UNSUPPORTED PICK"}]}]
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, partial]) as api, self.assertLogs("nba.chat") as logs:
            result = chat.run_analysis(request())
        self.assertEqual(api.call_count, 2)
        self.assertTrue(result["incomplete"])
        self.assertIn("50,000", result["text"])
        self.assertNotIn("UNSUPPORTED PICK", str(result) + str(logs.output))
        self.assertIn("reason=max_output_tokens", str(logs.output))
        self.assertEqual(result["output_tokens"], 50000)

    def test_luna_full_allowance_still_requires_budget(self):
        with patch.object(chat, "post_openai", return_value={"input_tokens": 1000}) as api:
            result = chat.run_analysis(request(budget=.01))
        self.assertEqual(api.call_count, 1)
        self.assertIn("50,000", result["notes"][0])
        self.assertEqual(result["estimated_cost"], 0)

    def test_other_model_output_limit_is_unchanged(self):
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response(model="gpt-6.1-sol")]) as api:
            chat.run_analysis(request(model="gpt-6.1-sol"))
        self.assertEqual(api.call_args.args[1]["max_output_tokens"], 2500)

    def test_timeout_diagnostics_do_not_claim_measured_usage(self):
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, TimeoutError("private-secret")]) as api, self.assertLogs("nba.chat") as logs:
            chat.run_analysis(request())
        self.assertEqual(api.call_count, 2)
        output = str(logs.output)
        self.assertIn("reason=timeout", output)
        self.assertIn("input_tokens=None", output)
        self.assertIn("cost_basis=reservation", output)
        self.assertNotIn("private-secret", output)

    def test_simple_question_extracts_completed_message(self):
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response(id="resp_safe123")]):
            result = chat.run_analysis(request(messages=[{"role": "user", "content": "What can you analyze?"}]))
        self.assertEqual(result["stop_reason"], "completed")
        self.assertFalse(result["incomplete"])
        self.assertEqual(result["diagnostics"][3]["response_id"], "resp_safe123")

    def test_broad_parlay_concludes_before_aggregate_input_exhaustion(self):
        import copy
        call = {"type": "function_call", "name": "get_players", "call_id": "db", "arguments": '{"ids":["p"]}'}
        research = {"type": "function_call", "name": "research", "call_id": "web", "arguments": '{"query":"current injuries and sportsbook lines"}'}
        usage = {"input_tokens": 12000, "output_tokens": 100}
        final = response(usage=usage, output=[{"type": "message", "content": [{"type": "output_text", "text": "Sportsbook lines could not be verified; no actionable parlay is available."}]}])
        results = iter([{"input_tokens": 12000}, response([call], usage=usage),
                        {"input_tokens": 12000}, response([research], usage=usage),
                        {"input_tokens": 12000}, {"input_tokens": 12000}, final])
        sent = []
        def provider(path, body):
            sent.append((path, copy.deepcopy(body)))
            return next(results)
        with patch.dict(os.environ, {"BRAVE_SEARCH_API_KEY": "fixture"}), patch.object(chat, "search", return_value={"sources": []}) as search, patch.object(chat, "post_openai", side_effect=provider):
            result = chat.run_analysis(request(context={"players": [{"id": "p", "logs": [{"PTS": 21}]}]}))
        self.assertEqual(result["stop_reason"], "completed")
        self.assertEqual(result["input_tokens"], 36000)
        self.assertEqual(result["tool_calls"], 2)
        search.assert_called_once()
        generations = [body for path, body in sent if path == "responses"]
        self.assertEqual(generations[-1]["tools"], [])
        self.assertEqual([b["max_output_tokens"] for b in generations], [50000]*3)
        outputs = [i for i in generations[-1]["input"] if i.get("type") == "function_call_output"]
        self.assertEqual([i["call_id"] for i in outputs], ["db", "web"])
        self.assertIn('"PTS":21', outputs[0]["output"])
        self.assertIn("could not be verified", result["text"])

    def test_empty_completed_response_is_not_success(self):
        empty = response(); empty["output"] = [{"type": "reasoning"}]
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, empty]) as api:
            result = chat.run_analysis(request())
        self.assertEqual(result["stop_reason"], "empty_response")
        self.assertTrue(result["incomplete"])
        self.assertEqual(api.call_count, 2)

    def test_input_budget_is_not_labeled_output_exhaustion(self):
        with patch.object(chat, "post_openai", return_value={"input_tokens": 17000}):
            result = chat.run_analysis(request())
        self.assertEqual(result["stop_reason"], "input_per_call_limit")
        self.assertIn("input_per_call_limit", result["text"])

    def test_failed_and_cancelled_responses_preserve_status(self):
        for status in ("failed", "cancelled"):
            with self.subTest(status=status), patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response(status=status)]):
                result = chat.run_analysis(request())
                self.assertEqual(result["stop_reason"], "openai_" + status)
                self.assertTrue(result["incomplete"])

    def test_shrinking_preflight_failure_returns_diagnostics(self):
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 15000}, TimeoutError()]) as api:
            result = chat.run_analysis(request(context={"players": [{"id": "p"}]}))
        self.assertEqual(result["stop_reason"], "preflight_timeout")
        self.assertEqual(result["estimated_cost"], 0)
        self.assertEqual(api.call_count, 2)

    def test_upstream_error_does_not_leak_keys_or_messages(self):
        import io
        from urllib.error import HTTPError
        from urllib.request import Request
        error = HTTPError("https://api.openai.com/v1/responses", 404, "not found", {},
                          io.BytesIO(b'{"error":{"code":"model_not_found","message":"secret-key and private prompt"}}'))
        with patch.object(chat, "urlopen", side_effect=error), self.assertLogs("nba.chat") as logs:
            with self.assertRaises(chat.ProviderFailure) as captured:
                chat.provider_json(Request("https://api.openai.com/v1/responses"), "OpenAI", "/v1/responses")
        self.assertIn("HTTP 404 (model_not_found)", str(captured.exception))
        self.assertNotIn("secret-key", str(captured.exception) + str(logs.output))
        self.assertNotIn("private prompt", str(logs.output))

    def test_status_checks_model_without_generation(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
            "NBA_CHAT_LEDGER": directory + "/ledger.sqlite", "NBA_CHAT_TOKEN": "fixture-token",
            "OPENAI_API_KEY": "fixture-not-a-key"}), patch.object(chat, "provider_json", return_value={"id": "gpt-6-luna"}) as provider:
            result = chat.chat_status("gpt-6-luna", "fixture-token")
        self.assertTrue(result["model_access"])
        self.assertEqual(result["protocol"], 1)  # Existing installed clients remain compatible.
        self.assertEqual(result["storage_mode"], "ephemeral")
        self.assertEqual(provider.call_args.args[2], "/v1/models/gpt-6-luna")

    def test_chat_routes_are_registered(self):
        from app import app
        routes = app.openapi()["paths"]
        self.assertIn("post", routes["/nba/chat"])
        self.assertIn("get", routes["/nba/chat/status"])

    def test_usage_categories_do_not_double_bill(self):
        usage = {"input_tokens": 10000, "output_tokens": 1000,
                 "input_tokens_details": {"cached_tokens": 2000, "cache_write_tokens": 3000,
                 "cache_write_tokens_details": {"ttl_12h_tokens": 1000}}}
        self.assertAlmostEqual(chat.usage_cost(usage, "gpt-6-luna"), .00152)

    def test_input_gate_prevents_generation(self):
        with patch.object(chat, "post_openai", return_value={"input_tokens": 20000}) as api:
            result = chat.run_analysis(request())
        self.assertTrue(result["incomplete"])
        self.assertEqual(result["estimated_cost"], 0)
        self.assertEqual(api.call_count, 1)
        self.assertEqual(api.call_args.args[0], "responses/input_tokens")

    def test_expensive_model_cannot_escape_budget(self):
        with patch.object(chat, "post_openai", return_value={"input_tokens": 10000}) as api:
            result = chat.run_analysis(request(model="gpt-6.1-sol", budget=.01))
        self.assertTrue(result["incomplete"])
        self.assertEqual(api.call_count, 1)

    def test_timeout_retains_reservation_without_retry(self):
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, TimeoutError()]) as api:
            result = chat.run_analysis(request())
        self.assertTrue(result["incomplete"])
        self.assertGreater(result["estimated_cost"], 0)
        self.assertEqual(api.call_count, 2)

    def test_stateless_request_has_no_hosted_search_or_full_catalog(self):
        player = {"id": "p", "name": "Player", "logs": [{"PTS": 20}]}
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response()]) as api:
            chat.run_analysis(request(context={"players": [player]}))
        body = api.call_args.args[1]
        self.assertEqual(body["prompt_cache_options"], {"mode": "explicit"})
        self.assertFalse(body["store"])
        self.assertNotIn('"logs"', body["input"][0]["content"])
        self.assertTrue(all(t["type"] == "function" for t in body["tools"]))

    def test_tool_history_is_targeted(self):
        call = {"type": "function_call", "name": "get_players", "call_id": "call-1", "arguments": '{"ids":["p"]}'}
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response([call]),
                                                           {"input_tokens": 1200}, response()]) as api:
            result = chat.run_analysis(request(context={"players": [{"id": "p", "logs": [{"PTS": None}]}]}))
        self.assertEqual(result["tool_calls"], 1)
        self.assertIn('"PTS":null', str(api.call_args.args[1]["input"]))

    def test_missing_usage_stops(self):
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response(usage=None)]):
            result = chat.run_analysis(request())
        self.assertTrue(result["incomplete"])
        self.assertGreater(result["estimated_cost"], 0)

    def test_duplicate_request_does_not_spend_again(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
            "NBA_CHAT_LEDGER": directory + "/ledger.sqlite", "NBA_CHAT_TOKEN": "fixture-token",
            "OPENAI_API_KEY": "fixture-not-a-key"}), patch.object(chat, "run_analysis", return_value={"estimated_cost": .01}) as run:
            first = chat.analyze(request(), "fixture-token")
            second = chat.analyze(request(), "fixture-token")
        self.assertEqual(first, second)
        self.assertEqual(run.call_count, 1)

    def test_unconfigured_auth_denied(self):
        with patch.dict(os.environ, {"NBA_CHAT_TOKEN": ""}):
            with self.assertRaises(HTTPException) as error:
                chat.authorize("")
        self.assertEqual(error.exception.status_code, 401)

    def test_daily_budget_includes_pending_reservations(self):
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, {
            "NBA_CHAT_LEDGER": directory + "/ledger.sqlite", "NBA_CHAT_TOKEN": "fixture-token",
            "OPENAI_API_KEY": "fixture-not-a-key", "NBA_CHAT_DAILY_USD": ".10"}), \
                patch.object(chat, "run_analysis", side_effect=TimeoutError()):
            with self.assertRaises(HTTPException):
                chat.analyze(request(), "fixture-token")
            with self.assertRaises(HTTPException) as error:
                chat.analyze(request(analysis_id="offline-analysis-002"), "fixture-token")
            self.assertEqual(error.exception.status_code, 429)

    def test_research_is_bounded_and_sources_are_retained(self):
        call = {"type": "function_call", "name": "research", "call_id": "search-1", "arguments": '{"query":"NBA injuries today"}'}
        source = {"title": "Injury report", "url": "https://www.nba.com/report", "excerpt": "Pending"}
        with patch.dict(os.environ, {"BRAVE_SEARCH_API_KEY": "fixture-not-a-key"}), \
                patch.object(chat, "search", return_value={"sources": [source]}) as search, \
                patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response([call]),
                                                               {"input_tokens": 1200}, response()]):
            result = chat.run_analysis(request(max_searches=1))
        self.assertEqual(search.call_count, 1)
        self.assertEqual(result["searches"], 1)
        self.assertEqual(result["sources"], [source])
        self.assertGreaterEqual(result["estimated_cost"], .005)

    def test_disabled_web_never_calls_search(self):
        call = {"type": "function_call", "name": "research", "call_id": "search-1", "arguments": '{"query":"NBA injuries"}'}
        with patch.object(chat, "search") as search, patch.object(chat, "post_openai", side_effect=[
                {"input_tokens": 1000}, response([call]), {"input_tokens": 1200}, response()]):
            result = chat.run_analysis(request(web=False))
        search.assert_not_called()
        self.assertEqual(result["searches"], 0)

    def test_initial_detail_shrinks_but_directory_remains(self):
        players = [{"id": str(i), "name": "Player " + str(i)} for i in range(8)]
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 13000},
                {"input_tokens": 11000}, response()]) as api:
            chat.run_analysis(request(context={"players": players}))
        evidence = api.call_args.args[1]["input"][0]["content"]
        self.assertIn('"omittedCandidates":4', evidence)
        self.assertIn('"id":"7"', evidence)

    def test_request_body_size_is_enforced_before_parsing(self):
        import asyncio
        from app import ChatBodyLimit
        events = []
        async def receive():
            return {"type": "http.request", "body": b"x" * 700001}
        async def send(event):
            events.append(event)
        async def downstream(*args):
            self.fail("Oversized upload reached JSON parsing")
        asyncio.run(ChatBodyLimit(downstream)({"type": "http", "path": "/nba/chat"}, receive, send))
        self.assertEqual(events[0]["status"], 413)


if __name__ == "__main__":
    unittest.main()
