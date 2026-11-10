"""Offline cost/security regression checks. Never use a real provider key."""
import os
import tempfile
import unittest
from unittest.mock import patch
from fastapi import HTTPException
import chat_api as chat


def request(**changes):
    values = dict(analysis_id="offline-analysis-001", context={"players": []}, web=False,
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
        for name in ("NBA_CHAT_DAILY_USD", "NBA_NATIVE_SEARCH_COST_USD"):
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
        self.assertIn("50,000", " ".join(result["notes"]))
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
            result = chat.run_analysis(request(web=False, messages=[{"role": "user", "content": "What can you analyze?"}]))
        self.assertEqual(result["stop_reason"], "completed")
        self.assertFalse(result["incomplete"])
        self.assertEqual(result["diagnostics"][3]["response_id"], "resp_safe123")


    def test_empty_completed_response_is_not_success(self):
        empty = response(); empty["output"] = [{"type": "reasoning"}]
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, empty]) as api:
            result = chat.run_analysis(request())
        self.assertEqual(result["stop_reason"], "empty_response")
        self.assertTrue(result["incomplete"])
        self.assertEqual(api.call_count, 2)

    def test_input_budget_is_not_labeled_output_exhaustion(self):
        with patch.object(chat, "post_openai", return_value={"input_tokens": 25000}):
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
            result = chat.run_analysis(request(max_input=12000, context={"players": [{"id": "p"}]}))
        self.assertEqual(result["stop_reason"], "preflight_timeout")
        self.assertEqual(result["estimated_cost"], 0)
        self.assertEqual(api.call_count, 2)

    def test_reported_input_growth_fits_new_separate_limits(self):
        call = {"type": "function_call", "name": "get_players", "call_id": "db", "arguments": '{"ids":["p"]}'}
        with patch.object(chat, "post_openai", side_effect=[
            {"input_tokens": 13000}, response([call], usage={"input_tokens": 13000, "output_tokens": 200}),
            {"input_tokens": 13397}, response([dict(call, call_id="again")], usage={"input_tokens": 13397, "output_tokens": 245}),
            {"input_tokens": 17923}, response(usage={"input_tokens": 17923, "output_tokens": 100})]) as api:
            result = chat.run_analysis(request(budget=.25, context={"players": [{"id": "p", "logs": [{"PTS": 21}]}]}))
        self.assertEqual(result["stop_reason"], "completed")
        self.assertEqual(result["input_tokens"], 44320)
        self.assertEqual(result["diagnostics"][0]["max_input"], 24000)
        self.assertEqual(result["diagnostics"][0]["aggregate_input_limit"], 100000)
        body = api.call_args.args[1]
        self.assertEqual(body["max_output_tokens"], 50000)
        outputs = [i for i in body["input"] if i.get("type") == "function_call_output"]
        import json
        self.assertEqual(json.loads(outputs[1]["output"])["players"], [])
        self.assertEqual(json.loads(outputs[1]["output"])["alreadyProvidedIDs"], ["p"])



    def test_budget_above_quarter_dollar_rejected(self):
        from pydantic import ValidationError
        with self.assertRaises(ValidationError):
            request(budget=.26)

    def test_invalid_input_env_fails_closed(self):
        for name in ("NBA_CHAT_MAX_INPUT_PER_CALL", "NBA_CHAT_MAX_INPUT_TOTAL"):
            for value in ("0", "nan", "-1", "1000001", ""):
                with patch.dict(os.environ, {name: value}), patch.object(chat, "post_openai") as api:
                    with self.assertRaises(HTTPException):
                        chat.run_analysis(request())
                    api.assert_not_called()

    def test_cumulative_ceiling_not_raised_by_per_call_setting(self):
        call = {"type": "function_call", "name": "get_players", "call_id": "db", "arguments": '{"ids":[]}'}
        fixtures = []
        for i in range(4):
            fixtures.extend([{"input_tokens": 24000}, response([dict(call, call_id=str(i))], usage={"input_tokens": 24000, "output_tokens": 100})])
            if i == 3:
                fixtures.insert(-1, {"input_tokens": 24000})
        fixtures.extend([{"input_tokens": 24000}, {"input_tokens": 24000}])
        with patch.object(chat, "post_openai", side_effect=fixtures) as api:
            result = chat.run_analysis(request())
        self.assertEqual(result["stop_reason"], "aggregate_input_limit")
        self.assertEqual(result["input_tokens"], 96000)
        self.assertEqual(sum(c.args[0] == "responses" for c in api.call_args_list), 4)



    def test_native_search_toggle_and_configuration(self):
        for enabled in (False, True):
            with self.subTest(enabled=enabled), patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response()]) as api:
                result = chat.run_analysis(request(web=enabled))
            body = api.call_args.args[1]
            native = [t for t in body["tools"] if t["type"] == "web_search"]
            self.assertEqual(bool(native), enabled)
            self.assertEqual(result["searches"], 0)  # Offering a tool is not execution.
            self.assertEqual(result["estimated_web_search_cost"], 0)
            if enabled:
                self.assertTrue(native[0]["external_web_access"])
                self.assertEqual(body["max_tool_calls"], 1)
                self.assertIn("web_search_call.action.sources", body["include"])
            else:
                self.assertNotIn("max_tool_calls", body)

    def test_native_search_citations_usage_and_broad_continuation(self):
        import copy
        source = {"url": "https://example.com/injury", "title": "Injury report"}
        web = {"type": "web_search_call", "status": "completed", "action": {"type": "search", "sources": [source]}}
        db = {"type": "function_call", "name": "get_players", "call_id": "db", "arguments": '{"ids":["p"]}'}
        final = {"type": "message", "content": [{"type": "output_text", "text": "No verified sportsbook lines; no actionable parlay.", "annotations": [{"type": "url_citation", "end_index": 48, **source}]}]}
        fixtures = iter([{"input_tokens": 1000}, response([db]), {"input_tokens": 1200}, response([web, dict(db, call_id="db2")]), {"input_tokens": 1400}, response([final])])
        sent = []
        def provider(path, body):
            sent.append((path, copy.deepcopy(body)))
            return next(fixtures)
        with patch.object(chat, "post_openai", side_effect=provider):
            result = chat.run_analysis(request(web=True, max_searches=1, context={"players": [{"id": "p", "logs": [{"PTS": 21}]}]}))
        self.assertEqual(result["stop_reason"], "completed")
        self.assertEqual(result["searches"], 1)
        self.assertEqual(result["successful_searches"], 1)
        self.assertEqual(result["native_search_available"], "confirmed_by_execution")
        self.assertEqual(result["estimated_web_search_cost"], .01)
        self.assertAlmostEqual(result["estimated_cost"], result["estimated_model_cost"] + .01)
        self.assertIn("[source](https://example.com/injury)", result["text"])
        self.assertIn("retrieved_at", result["sources"][0])
        self.assertIn("not_independent_verification", result["sources"][0]["verification"])
        last = sent[-1][1]
        self.assertFalse(any(t["type"] == "web_search" for t in last["tools"]))
        self.assertTrue(any(i.get("type") == "function_call_output" for i in last["input"]))
        self.assertTrue(any(i.get("type") == "web_search_call" for i in last["input"]))
        self.assertEqual(last["max_output_tokens"], 50000)

    def test_search_rejection_stops_without_retry_or_fake_count(self):
        failure = chat.ProviderFailure("OpenAI", "/v1/responses", 400, "unsupported_tool")
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, failure]) as api:
            result = chat.run_analysis(request(web=True))
        self.assertEqual(api.call_count, 2)
        self.assertEqual(result["native_search_available"], "rejected")
        self.assertEqual(result["searches"], 0)
        self.assertEqual(result["sources"], [])
        self.assertGreater(result["uncertain_cost_reservation"], 0)

    def test_failed_search_not_counted_completed(self):
        web = {"type": "web_search_call", "status": "failed", "action": {"type": "search", "sources": [{"url": "https://example.com"}]}}
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response([web, {"type": "message", "content": [{"text": "Research failed."}]}])]):
            result = chat.run_analysis(request(web=True))
        self.assertEqual(result["searches"], 0)
        self.assertEqual(result["web_actions"], 1)
        self.assertEqual(result["sources"], [])
        self.assertEqual(result["estimated_web_search_cost"], .01)  # Conservative attempted-action accounting.
        self.assertIn("remain unverified", result["text"])

    def test_native_fee_and_content_reserve_can_block_generation(self):
        with patch.object(chat, "post_openai", return_value={"input_tokens": 1000}) as api:
            result = chat.run_analysis(request(web=True, budget=.03))
        self.assertEqual(result["stop_reason"], "spending_limit")
        self.assertEqual(api.call_count, 1)
        self.assertEqual(result["estimated_cost"], 0)

    def test_search_limit_and_headroom_configuration(self):
        with patch.dict(os.environ, {"NBA_CHAT_MAX_WEB_SEARCHES": "0"}), patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response()]) as api:
            result = chat.run_analysis(request(web=True))
        self.assertFalse(any(t["type"] == "web_search" for t in api.call_args.args[1]["tools"]))
        self.assertEqual(result["searches"], 0)
        with patch.object(chat, "post_openai", return_value={"input_tokens": 19000}) as api:
            result = chat.run_analysis(request(web=True))
        self.assertEqual(result["stop_reason"], "input_per_call_limit")
        self.assertEqual(api.call_count, 1)

    def test_search_reported_usage_overrun_stops_without_more_calls(self):
        web = {"type": "web_search_call", "status": "completed", "action": {"type": "search"}}
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response([web], usage={"input_tokens": 25000, "output_tokens": 100})]) as api:
            result = chat.run_analysis(request(web=True))
        self.assertEqual(result["stop_reason"], "reported_usage_limit_exceeded")
        self.assertEqual(api.call_count, 2)
        self.assertEqual(result["input_tokens"], 25000)

    def test_native_search_budget_cannot_be_underpriced(self):
        with patch.dict(os.environ, {"NBA_NATIVE_SEARCH_COST_USD": ".005"}), patch.object(chat, "post_openai") as api:
            with self.assertRaises(HTTPException):
                chat.run_analysis(request())
            api.assert_not_called()

    def test_native_timeout_does_not_invent_completed_search(self):
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, TimeoutError()]) as api:
            result = chat.run_analysis(request(web=True))
        self.assertEqual(api.call_count, 2)
        self.assertEqual(result["searches"], 0)
        self.assertEqual(result["web_actions"], 0)
        self.assertEqual(result["native_search_available"], "not_tested")
        self.assertEqual(result["stop_reason"], "timeout")
        self.assertAlmostEqual(result["estimated_cost"], result["uncertain_cost_reservation"])

    def test_native_page_open_uses_action_allowance_but_not_search_fee(self):
        page = {"type": "web_search_call", "status": "completed", "action": {"type": "open_page", "url": "https://example.com"}}
        message = {"type": "message", "content": [{"text": "No verified odds.", "annotations": [{"type": "url_citation", "url": "https://example.com", "end_index": 17}]}]}
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 1000}, response([page, message])]):
            result = chat.run_analysis(request(web=True))
        self.assertEqual(result["web_actions"], 1)
        self.assertEqual(result["searches"], 0)
        self.assertEqual(result["estimated_web_search_cost"], 0)
        self.assertEqual(len(result["sources"]), 1)

    def test_native_config_invalid_values_fail_before_dispatch(self):
        for name in ("NBA_CHAT_MAX_WEB_SEARCHES", "NBA_CHAT_SEARCH_INPUT_RESERVE"):
            for value in ("nan", "-1", "100000", ""):
                with self.subTest(name=name, value=value), patch.dict(os.environ, {name: value}), patch.object(chat, "post_openai") as api:
                    with self.assertRaises(HTTPException):
                        chat.run_analysis(request(web=True))
                    api.assert_not_called()

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
        with patch.object(chat, "post_openai", return_value={"input_tokens": 25000}) as api:
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



    def test_initial_detail_shrinks_but_directory_remains(self):
        players = [{"id": str(i), "name": "Player " + str(i)} for i in range(8)]
        with patch.object(chat, "post_openai", side_effect=[{"input_tokens": 13000},
                {"input_tokens": 11000}, response()]) as api:
            chat.run_analysis(request(max_input=12000, context={"players": players}))
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
